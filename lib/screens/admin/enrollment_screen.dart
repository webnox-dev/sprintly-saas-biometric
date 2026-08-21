import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../services/fingerprint_service.dart';
import '../../services/backend_attendance_service.dart';
import '../../services/face_embedding_service.dart';
import '../../api/backend_api.dart';

enum EnrollmentStep { selectEmployee, fingerprint, face, pin, complete }

class EnrollmentScreen extends StatefulWidget {
  final EmployeeForEnrollment? initialEmployee;
  const EnrollmentScreen({super.key, this.initialEmployee});

  @override
  State<EnrollmentScreen> createState() => _EnrollmentScreenState();
}

class _EnrollmentScreenState extends State<EnrollmentScreen> {
  CameraController? _cameraController;
  late FaceEmbeddingService _embeddingService;
  late FingerprintService _fingerprintService;
  late BackendAttendanceService _attendanceService;
  late BackendApi _backendApi;
  late FaceDetector _faceDetector;

  bool _isInitialized = false;
  EnrollmentStep _currentStep = EnrollmentStep.selectEmployee;
  bool _isScanning = false;
  bool _isCapturing = false;
  bool _isEnrolling = false;
  bool _isLoadingEmployees = false;
  String _statusMessage = '';

  // Employee Selection
  List<EmployeeForEnrollment> _employees = [];
  EmployeeForEnrollment? _selectedEmployee;

  // Face Capture State (3 Angles)
  final List<Uint8List> _capturedImages = [];
  final List<Map<String, int>> _capturedFaceRects = [];
  static const int _requiredCaptures = 3;
  final List<String> _captureInstructions = [
    'Photo 1 - Look at camera',
    'Photo 2 - Slight smile',
    'Photo 3 - Neutral expression',
  ];

  // Fingerprint Capture State
  List<String> _capturedFingerprints = [];
  static const int _requiredFingerprintCaptures = 4;

  bool get _allFaceCaptured => _capturedImages.length >= _requiredCaptures;
  int get _currentFaceIndex => _capturedImages.length;

  // PIN Capture State
  final TextEditingController _pinController = TextEditingController();
  bool _isPinVisible = false;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    _fingerprintService = FingerprintService();
    _embeddingService = FaceEmbeddingService();
    _backendApi = BackendApi();
    _attendanceService = BackendAttendanceService(
      _backendApi,
      _embeddingService,
      _fingerprintService,
    );

    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: true,
        enableClassification: true,
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.1,
      ),
    );

    try {
      print('EnrollmentScreen: Initializing face embedding service...');
      await _embeddingService.init();
    } catch (e) {
      print('Warning: Face embedding service init failed: $e');
    }

    // Initialize Fingerprint Service
    try {
      print('EnrollmentScreen: Initializing fingerprint service...');
      final fpSuccess = await _fingerprintService.initialize();
      if (!fpSuccess) {
        print(
          'Warning: Fingerprint init failed: ${_fingerprintService.lastError}',
        );
        setState(() {
          _statusMessage = 'Fingerprint scanner not detected or failed to init';
        });
      }
    } catch (e) {
      print('Warning: Fingerprint service init threw exception: $e');
      setState(() {
        _statusMessage = 'Fingerprint scanner error: $e';
      });
    }

    // Always fetch employees regardless of biometric init status
    try {
      print('EnrollmentScreen: Fetching employees...');
      await _fetchEmployees();
    } catch (e) {
      print('Error fetching employees: $e');
    }

    if (widget.initialEmployee != null) {
      _selectedEmployee = widget.initialEmployee;
      _currentStep = EnrollmentStep.fingerprint; // Skip selection step
    }

    setState(() => _isInitialized = true);
    print('EnrollmentScreen: Initialization complete.');
  }

  Future<void> _initializeCamera() async {
    // Add a small delay to ensure previous camera session has fully released
    await Future.delayed(const Duration(milliseconds: 500));

    if (!mounted) return;

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      setState(() => _statusMessage = 'No cameras found on device');
      return;
    }

    final frontCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      frontCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21, // Android-friendly format
    );

    _cameraController = controller;

    try {
      await controller.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      print('Error initializing camera: $e');
      setState(() => _statusMessage = 'Camera error: $e');
    }
  }

  Future<void> _fetchEmployees() async {
    setState(() => _isLoadingEmployees = true);
    try {
      print('Fetching employees for enrollment...');
      final employees = await _attendanceService.getEmployeesForEnrollment();
      setState(() {
        _employees = employees;
        _isLoadingEmployees = false;
        if (_employees.isEmpty) {
          _statusMessage = 'No employees found in database';
        }
      });
    } catch (e) {
      print('Failed to load employees: $e');
      setState(() {
        _statusMessage = 'Error loading employees: $e';
        _isLoadingEmployees = false;
      });
    }
  }

  // --- Step Management ---

  Future<void> _nextStep() async {
    if (_currentStep == EnrollmentStep.selectEmployee) {
      if (_selectedEmployee == null) {
        setState(() => _statusMessage = 'Please select an employee first');
        return;
      }
      setState(() {
        _currentStep = EnrollmentStep.fingerprint;
        _statusMessage = '';
      });
    } else if (_currentStep == EnrollmentStep.fingerprint) {
      // Validation: Fingerprint is now optional (admin can skip)
      
      // Always go to Face step to allow update
      setState(() {
        _currentStep = EnrollmentStep.face;
        _statusMessage = '';
      });
      _initializeCamera();
    } else if (_currentStep == EnrollmentStep.face) {
      // Validation: Must capture OR have existing enrolled
      if (!_allFaceCaptured && _selectedEmployee?.hasFaceEnrolled != true) {
        setState(() => _statusMessage = 'Please capture all 3 face photos');
        return;
      }
      _stopCamera();
      setState(() {
        _currentStep = EnrollmentStep.pin;
        _statusMessage = '';
      });
    } else if (_currentStep == EnrollmentStep.pin) {
      // Validation: PIN should be 4 digits if entered
      if (_pinController.text.isNotEmpty && _pinController.text.length != 4) {
        setState(() => _statusMessage = 'PIN must be 4 digits');
        return;
      }

      // Check for duplicate PIN before proceeding
      if (_pinController.text.length == 4) {
        setState(() => _statusMessage = 'Checking PIN availability...');
        try {
          final available = await _backendApi.checkPinAvailable(
            pin: _pinController.text,
            excludeEmployeeId: _selectedEmployee?.employeeId,
          );
          if (!available) {
            setState(() {
              _statusMessage =
                  '❌ This PIN is already used by another employee. Please choose a different PIN.';
            });
            return;
          }
        } catch (e) {
          // If check fails, allow proceeding (backend will still validate)
          print('PIN check error: $e');
        }
      }

      setState(() {
        _currentStep = EnrollmentStep.complete;
        _statusMessage = '';
      });
    }
  }

  void _previousStep() {
    setState(() {
      _statusMessage = '';
      if (_currentStep == EnrollmentStep.fingerprint) {
        _capturedFingerprints.clear(); // Clear when going back to select
        _currentStep = EnrollmentStep.selectEmployee;
      } else if (_currentStep == EnrollmentStep.face) {
        _stopCamera();
        _capturedImages.clear(); // Clear when going back to fingerprint
        _capturedFaceRects.clear();
        _currentStep = EnrollmentStep.fingerprint;
      } else if (_currentStep == EnrollmentStep.pin) {
        _currentStep = EnrollmentStep.face;
        _initializeCamera();
      } else if (_currentStep == EnrollmentStep.complete) {
        _currentStep = EnrollmentStep.pin;
      }
    });
  }

  // --- Biometric Logic ---

  Future<void> _captureFingerprint() async {
    if (_isScanning) return;
    setState(() {
      _isScanning = true;
      _statusMessage = 'Place finger on scanner...';
    });

    try {
      // Ensure device is initialized before capture
      if (!_fingerprintService.isInitialized) {
        await _fingerprintService.initialize();
      }

      final result = await _fingerprintService.captureFingerprint();
      if (result.success && result.fingerprintTemplate != null) {
        setState(() {
          _capturedFingerprints.add(result.fingerprintTemplate!);
          if (_capturedFingerprints.length >= _requiredFingerprintCaptures) {
            _statusMessage = '✅ Fingerprint captured successfully!';
          } else {
            _statusMessage = '✅ Scan ${_capturedFingerprints.length} of $_requiredFingerprintCaptures successful. Place finger again slightly differently.';
          }
        });
        
        if (_capturedFingerprints.length >= _requiredFingerprintCaptures) {
          await Future.delayed(const Duration(milliseconds: 1000));
          _nextStep();
        }
      } else {
        // Handle specific "already in progress" error from our new native code
        if (result.errorMessage?.contains('progress') == true) {
          setState(
            () => _statusMessage =
                '⚠️ Device busy. Please wait a moment and try again.',
          );
        } else {
          setState(
            () => _statusMessage =
                '❌ Capture failed: ${result.errorMessage ?? "Unknown error"}',
          );
        }
      }
    } catch (e) {
      print('EnrollmentScreen Capture Error: $e');
      setState(() => _statusMessage = '❌ Error: $e');
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  Future<void> _capturePhoto() async {
    if (_cameraController == null || _allFaceCaptured || _isCapturing) return;

    setState(() {
      _isCapturing = true;
      _statusMessage = 'Detecting face...';
    });

    try {
      final image = await _cameraController!.takePicture();
      final bytes = await image.readAsBytes();

      // Validate face
      final inputImage = InputImage.fromFilePath(image.path);
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        setState(() {
          _isCapturing = false;
          _statusMessage = '❌ No face detected. Try again.';
        });
        return;
      }

      final faceRect = {
        'x': faces.first.boundingBox.left.toInt(),
        'y': faces.first.boundingBox.top.toInt(),
        'width': faces.first.boundingBox.width.toInt(),
        'height': faces.first.boundingBox.height.toInt(),
      };

      setState(() {
        _capturedImages.add(bytes);
        _capturedFaceRects.add(faceRect);
        _isCapturing = false;
        if (_allFaceCaptured) {
          _statusMessage = '✅ Face capture complete!';
        } else {
          _statusMessage =
              '✅ Photo ${_capturedImages.length}/$_requiredCaptures valid!';
        }
      });
    } catch (e) {
      setState(() {
        _isCapturing = false;
        _statusMessage = '❌ Photo capture failed: $e';
      });
    }
  }

  Future<void> _enrollEmployee() async {
    setState(() {
      _isEnrolling = true;
      _statusMessage = 'Saving enrollment to server...';
    });

    try {
      print('-----------------------------------------');
      print('🚀 STARTING ENROLLMENT PROCESS');
      print(
        'Employee: ${_selectedEmployee?.employeeName} (${_selectedEmployee?.employeeId})',
      );
      print('Images: ${_capturedImages.length}');
      print(
        'Fingerprint: ${_capturedFingerprints.isNotEmpty ? 'Present (${_capturedFingerprints.length})' : 'Missing'}',
      );

      // Reuse existing data logic
      String? existingEmbeddingStr;
      String? existingFingerprintTemplate;
      String? existingPin;

      if ((_capturedImages.isEmpty &&
              _selectedEmployee?.hasFaceEnrolled == true) ||
          (_capturedFingerprints.isEmpty &&
              _selectedEmployee?.hasFingerprintEnrolled == true) ||
          (_pinController.text.isEmpty &&
              _selectedEmployee?.hasPinEnrolled == true)) {
        try {
          print(
            'Fetching existing details for ${_selectedEmployee!.employeeId}...',
          );
          final existing = await _attendanceService.getEmployeeDetails(
            _selectedEmployee!.employeeId,
          );

          if (existing != null) {
            // Recover Face
            if (_capturedImages.isEmpty && existing.embedding.isNotEmpty) {
              existingEmbeddingStr = existing.embedding.join(',');
              print('✅ Reusing existing face embedding');
            }
            // Recover Fingerprint
            if (_capturedFingerprints.isEmpty &&
                existing.fingerprintTemplate != null) {
              existingFingerprintTemplate = existing.fingerprintTemplate;
              print('✅ Reusing existing fingerprint template');
            }
            // Recover PIN
            if (_pinController.text.isEmpty && existing.pin != null) {
              existingPin = existing.pin;
              print('✅ Reusing existing PIN');
            }
          }
        } catch (e) {
          print('⚠️ Error recovering existing data: $e');
        }
      }

      final success = await _attendanceService.enrollEmployee(
        employeeId: _selectedEmployee!.employeeId,
        name: _selectedEmployee!.employeeName,
        department: _selectedEmployee!.department,
        faceImages: _capturedImages,
        faceRects: _capturedFaceRects,
        fingerprintTemplate: _capturedFingerprints.isNotEmpty ? jsonEncode(_capturedFingerprints) : null,
        pin: _pinController.text.isNotEmpty ? _pinController.text : null,
        existingEmbedding: existingEmbeddingStr,
        existingFingerprintTemplate: existingFingerprintTemplate,
        existingPin: existingPin,
      );

      print('Enrollment API result: $success');

      if (success) {
        print('✅ Enrollment successful on server.');
        setState(() {
          _statusMessage = '✅ Enrollment Successful!';
          _isEnrolling = false;
        });
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) Navigator.pop(context, true);
      } else {
        print('❌ Server rejected enrollment (success=false)');
        setState(() {
          _statusMessage = '❌ Server rejected enrollment';
          _isEnrolling = false;
        });
      }
    } catch (e, stackTrace) {
      print('❌ ENROLLMENT ERROR: $e');
      print('Stack trace: $stackTrace');
      setState(() {
        _statusMessage = '❌ Enrollment failed: $e';
        _isEnrolling = false;
      });
    } finally {
      print('🔚 ENROLLMENT PROCESS FINISHED');
      print('-----------------------------------------');
    }
  }

  Future<void> _stopCamera() async {
    final controller = _cameraController;
    _cameraController = null;
    await controller?.dispose();
  }

  @override
  void dispose() {
    _stopCamera();
    _faceDetector.close();
    _pinController.dispose();
    super.dispose();
  }

  // --- UI Build ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          'New Enrollment',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
      ),
      body: !_isInitialized
          ? _buildLoading()
          : Column(
              children: [
                _buildProgressBar(),
                Expanded(
                  child: _currentStep == EnrollmentStep.face
                      ? Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: _buildCurrentStepView(),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: _buildCurrentStepView(),
                        ),
                ),
                _buildNavigationFooter(),
              ],
            ),
    );
  }

  Widget _buildProgressBar() {
    double progress = (_currentStep.index + 1) / EnrollmentStep.values.length;
    return Column(
      children: [
        LinearProgressIndicator(
          value: progress,
          backgroundColor: Colors.white10,
          valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade400),
          minHeight: 4,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildStepIndicator(0, 'Select'),
              _buildStepIndicator(1, 'Finger'),
              _buildStepIndicator(2, 'Face'),
              _buildStepIndicator(3, 'PIN'),
              _buildStepIndicator(4, 'Review'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStepIndicator(int index, String label) {
    bool isActive = _currentStep.index == index;
    bool isDone = _currentStep.index > index;
    return Column(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDone
                ? Colors.green
                : (isActive ? Colors.blue : Colors.white10),
            border: Border.all(
              color: isActive ? Colors.blue.shade200 : Colors.transparent,
              width: 2,
            ),
          ),
          child: Center(
            child: isDone
                ? const Icon(Icons.check, size: 16, color: Colors.white)
                : Text(
                    '${index + 1}',
                    style: TextStyle(
                      color: isActive || isDone ? Colors.white : Colors.white38,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: isActive ? Colors.blue : Colors.white38,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _buildCurrentStepView() {
    switch (_currentStep) {
      case EnrollmentStep.selectEmployee:
        return _buildEmployeeSelection();
      case EnrollmentStep.fingerprint:
        return _buildFingerprintCapture();
      case EnrollmentStep.face:
        return _buildFaceCapture();
      case EnrollmentStep.pin:
        return _buildPinStep();
      case EnrollmentStep.complete:
        return _buildReviewAndComplete();
    }
  }

  Widget _buildEmployeeSelection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Step 1: Select Employee',
          style: GoogleFonts.poppins(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Choose the person you want to enroll in the system.',
          style: GoogleFonts.poppins(fontSize: 14, color: Colors.white54),
        ),
        const SizedBox(height: 32),
        if (_isLoadingEmployees)
          const Center(child: CircularProgressIndicator())
        else if (_employees.isEmpty)
          _buildEmptyState()
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<EmployeeForEnrollment>(
                value: _selectedEmployee,
                isExpanded: true,
                dropdownColor: Colors.grey.shade900,
                hint: const Text(
                  'Select an employee',
                  style: TextStyle(color: Colors.white38),
                ),
                items: _employees.map((e) {
                  return DropdownMenuItem(
                    value: e,
                    child: Row(
                      children: [
                        Text(
                          e.employeeName,
                          style: const TextStyle(color: Colors.white),
                        ),
                        const Spacer(),
                        if (e.hasFingerprintEnrolled)
                          const Icon(
                            Icons.fingerprint,
                            size: 16,
                            color: Colors.purpleAccent,
                          ),
                        if (e.hasFaceEnrolled)
                          const Icon(
                            Icons.face,
                            size: 16,
                            color: Colors.blueAccent,
                          ),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (val) {
                  setState(() {
                    _selectedEmployee = val;
                    _statusMessage = '';
                  });
                },
              ),
            ),
          ),
        if (_selectedEmployee != null) ...[
          const SizedBox(height: 24),
          _buildEmployeeCard(),
        ],
        if (_statusMessage.isNotEmpty) _buildStatusText(),
      ],
    );
  }

  Widget _buildFingerprintCapture() {
    final bool isEnrolled = _selectedEmployee?.hasFingerprintEnrolled ?? false;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    // --- LANDSCAPE LAYOUT ---
    if (isLandscape) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // LEFT: Instructions & Status
          Expanded(
            flex: 5,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Step 2: Fingerprint',
                  style: GoogleFonts.poppins(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Place the employee\'s finger on the Mantra scanner.',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(height: 32),

                // Status Text
                Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 16,
                    horizontal: 20,
                  ),
                  decoration: BoxDecoration(
                    color: _capturedFingerprints.length >= _requiredFingerprintCaptures
                        ? Colors.green.withOpacity(0.1)
                        : Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _capturedFingerprints.length >= _requiredFingerprintCaptures
                          ? Colors.green.withOpacity(0.5)
                          : Colors.white10,
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        _capturedFingerprints.length >= _requiredFingerprintCaptures
                            ? 'Fingerprints Captured!'
                            : (_isScanning
                                  ? 'Scanner Active...'
                                  : 'Touch the icon on the right to start scan'),
                        textAlign: TextAlign.center,
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _capturedFingerprints.length >= _requiredFingerprintCaptures
                              ? Colors.green
                              : Colors.white70,
                        ),
                      ),
                      if (isEnrolled && _capturedFingerprints.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '(Already Enrolled - Scan again to update)',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.orange.shade300,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                if (_statusMessage.isNotEmpty) _buildStatusText(),

                const SizedBox(height: 24),
                // Skip Button for Landscape
                if (_capturedFingerprints.length < _requiredFingerprintCaptures)
                  OutlinedButton.icon(
                    onPressed: _nextStep,
                    icon: const Icon(Icons.skip_next),
                    label: const Text('Skip Fingerprint for now'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                    ),
                  ),
              ],
            ),
          ),

          // RIGHT: Scanner Button
          Expanded(
            flex: 6,
            child: Center(
              child: GestureDetector(
                onTap: _isScanning ? null : _captureFingerprint,
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _capturedFingerprints.length >= _requiredFingerprintCaptures
                        ? Colors.green.withOpacity(0.1)
                        : Colors.blue.withOpacity(0.05),
                    border: Border.all(
                      color: _capturedFingerprints.length >= _requiredFingerprintCaptures
                          ? Colors.green
                          : Colors.blue.withOpacity(0.3),
                      width: 2,
                    ),
                    boxShadow: [
                      if (_isScanning)
                        BoxShadow(
                          color: Colors.blue.withOpacity(0.2),
                          blurRadius: 40,
                          spreadRadius: 10,
                        ),
                    ],
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(
                        Icons.fingerprint_rounded,
                        size: 110,
                        color: _capturedFingerprints.length >= _requiredFingerprintCaptures
                            ? Colors.green
                            : Colors.blue.withOpacity(0.5),
                      ),
                      if (_isScanning)
                        const SizedBox(
                          width: 220,
                          height: 220,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: Colors.blue,
                          ),
                        ),
                      Positioned(
                        bottom: 20,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: List.generate(_requiredFingerprintCaptures, (index) {
                            bool isCaptured = index < _capturedFingerprints.length;
                            return Container(
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isCaptured ? Colors.green : Colors.transparent,
                                border: Border.all(
                                  color: isCaptured ? Colors.green : Colors.blue.withOpacity(0.5),
                                ),
                              ),
                            );
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    // --- PORTRAIT LAYOUT ---
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Step 2: Fingerprint',
          style: GoogleFonts.poppins(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Place the employee\'s finger on the Mantra scanner.',
          style: GoogleFonts.poppins(fontSize: 14, color: Colors.white54),
        ),
        const SizedBox(height: 48),
        GestureDetector(
          onTap: _isScanning ? null : _captureFingerprint,
          child: Center(
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _capturedFingerprints.length >= _requiredFingerprintCaptures
                    ? Colors.green.withOpacity(0.1)
                    : Colors.blue.withOpacity(0.05),
                border: Border.all(
                  color: _capturedFingerprints.length >= _requiredFingerprintCaptures
                      ? Colors.green
                      : Colors.blue.withOpacity(0.3),
                  width: 2,
                ),
                boxShadow: [
                  if (_isScanning)
                    BoxShadow(
                      color: Colors.blue.withOpacity(0.2),
                      blurRadius: 30,
                      spreadRadius: 10,
                    ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.fingerprint_rounded,
                    size: 100,
                    color: _capturedFingerprints.length >= _requiredFingerprintCaptures
                        ? Colors.green
                        : Colors.blue.withOpacity(0.5),
                  ),
                  if (_isScanning)
                    const CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.blue,
                    ),
                  Positioned(
                    bottom: 20,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(_requiredFingerprintCaptures, (index) {
                        bool isCaptured = index < _capturedFingerprints.length;
                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isCaptured ? Colors.green : Colors.transparent,
                            border: Border.all(
                              color: isCaptured ? Colors.green : Colors.blue.withOpacity(0.5),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
        Text(
          _capturedFingerprints.length >= _requiredFingerprintCaptures
              ? 'Fingerprints Captured!'
              : (_isScanning ? 'Scanner Active...' : 'Touch to Start Scan'),
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: _capturedFingerprints.length >= _requiredFingerprintCaptures ? Colors.green : Colors.white70,
          ),
        ),
        if (isEnrolled && _capturedFingerprints.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '(Already Enrolled - Scan again to Update)',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.orange.shade300, fontSize: 12),
            ),
          ),
        const SizedBox(height: 24),
        if (_statusMessage.isNotEmpty) _buildStatusText(),
        
        const SizedBox(height: 16),
        // Skip Button for Portrait
        if (_capturedFingerprints.length < _requiredFingerprintCaptures)
          Center(
            child: TextButton.icon(
              onPressed: _nextStep,
              icon: const Icon(Icons.skip_next, size: 18),
              label: const Text('Skip Fingerprint for now'),
              style: TextButton.styleFrom(foregroundColor: Colors.white38),
            ),
          ),
      ],
    );
  }

  Widget _buildFaceCapture() {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    if (isLandscape) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // LEFT SIDE: Controls & Instructions
          Expanded(
            flex: 4,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Step 3: Face Photos',
                  style: GoogleFonts.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Capture 3 photos.',
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(height: 20),

                // Progress Dots
                Row(
                  children: List.generate(_requiredCaptures, (index) {
                    bool isDone = index < _capturedImages.length;
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isDone
                            ? Colors.green
                            : Colors.white.withOpacity(0.05),
                        border: Border.all(
                          color: isDone ? Colors.green : Colors.white24,
                        ),
                      ),
                      child: isDone
                          ? const Icon(
                              Icons.check,
                              size: 16,
                              color: Colors.white,
                            )
                          : Center(
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(color: Colors.white54),
                              ),
                            ),
                    );
                  }),
                ),

                if (_selectedEmployee?.hasFaceEnrolled == true)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.info_outline,
                          color: Colors.orangeAccent,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Already enrolled. Click NEXT to keep.',
                            style: GoogleFonts.poppins(
                              color: Colors.orange.shade200,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                const Spacer(),

                // Instruction Text
                if (!_allFaceCaptured)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue.withOpacity(0.3)),
                    ),
                    child: Text(
                      _captureInstructions[_currentFaceIndex],
                      textAlign: TextAlign.center,
                      style: GoogleFonts.poppins(
                        color: Colors.blue.shade100,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),

                const SizedBox(height: 16),

                // Capture Button
                if (!_allFaceCaptured)
                  SizedBox(
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: _isCapturing ? null : _capturePhoto,
                      icon: const Icon(Icons.camera_alt_rounded),
                      label: Text(
                        _isCapturing ? 'Processing...' : 'Capture Photo',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade600,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  )
                else
                  SizedBox(
                    height: 50,
                    child: OutlinedButton.icon(
                      onPressed: () => setState(() => _capturedImages.clear()),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retake Photos'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white24),
                      ),
                    ),
                  ),

                if (_statusMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _statusMessage.contains('✅')
                            ? Colors.green
                            : Colors.redAccent,
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // RIGHT SIDE: Camera Preview
          Expanded(
            flex: 6,
            child: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: _buildCameraPreview(),
            ),
          ),
        ],
      );
    }

    // --- PORTRAIT LAYOUT (Existing) ---
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header row: title + progress dots
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Step 3: Face Photos',
                    style: GoogleFonts.poppins(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Capture 3 photos from different angles.',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
            // Compact progress dots
            Row(
              children: List.generate(_requiredCaptures, (index) {
                bool isDone = index < _capturedImages.length;
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDone
                        ? Colors.green
                        : Colors.white.withOpacity(0.05),
                    border: Border.all(
                      color: isDone ? Colors.green : Colors.white24,
                      width: 1.5,
                    ),
                  ),
                  child: isDone
                      ? const Icon(Icons.check, size: 14, color: Colors.white)
                      : Center(
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                        ),
                );
              }),
            ),
          ],
        ),

        if (_selectedEmployee?.hasFaceEnrolled == true)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline,
                  color: Colors.orangeAccent,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Already enrolled. Click NEXT to keep or capture new.',
                    style: GoogleFonts.poppins(
                      color: Colors.orange.shade200,
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ),
          ),

        const SizedBox(height: 8),

        if (!_allFaceCaptured) ...[
          // Instruction text
          Text(
            _captureInstructions[_currentFaceIndex],
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              color: Colors.blue.shade200,
              fontWeight: FontWeight.w500,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),

          // Camera preview with face oval mask - fills available space
          Expanded(child: _buildCameraPreview()),

          const SizedBox(height: 10),

          // Capture button
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _isCapturing ? null : _capturePhoto,
              icon: Icon(
                _isCapturing ? Icons.hourglass_top : Icons.camera_alt_rounded,
                size: 20,
              ),
              label: Text(
                _isCapturing
                    ? 'Processing...'
                    : 'Capture Photo ${_currentFaceIndex + 1}/$_requiredCaptures',
                style: const TextStyle(fontSize: 14),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade600,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ] else
          Expanded(child: _buildFaceThumbnails()),

        if (_statusMessage.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _statusMessage.contains('✅')
                    ? Colors.green
                    : Colors.redAccent,
                fontWeight: FontWeight.w500,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCameraPreview() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Camera preview
          _cameraController?.value.isInitialized == true
              ? FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _cameraController!.value.previewSize!.height,
                    height: _cameraController!.value.previewSize!.width,
                    child: CameraPreview(_cameraController!),
                  ),
                )
              : Container(
                  color: Colors.white.withOpacity(0.05),
                  child: const Center(child: CircularProgressIndicator()),
                ),

          // Face oval mask overlay
          CustomPaint(
            painter: _FaceOvalMaskPainter(),
            child: const SizedBox.expand(),
          ),

          // Oval guide border with corner markers
          Center(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Calculate size based on the specific container size
                // Use the smaller dimension to keep it oval/circular and not stretched
                final size = constraints.maxWidth < constraints.maxHeight
                    ? constraints.maxWidth
                    : constraints.maxHeight;

                final ovalWidth = size * 0.65;
                final ovalHeight = size * 0.8; // Taller than wide for face

                return SizedBox(
                  width: ovalWidth,
                  height: ovalHeight,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(ovalWidth / 2),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.8),
                        width: 2.5,
                      ),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Top marker
                        Positioned(
                          top: ovalHeight * 0.1,
                          child: _buildGuideMarker(),
                        ),
                        // Bottom marker
                        Positioned(
                          bottom: ovalHeight * 0.1,
                          child: _buildGuideMarker(),
                        ),
                        // Left marker
                        Positioned(
                          left: ovalWidth * 0.1,
                          child: _buildGuideMarker(),
                        ),
                        // Right marker
                        Positioned(
                          right: ovalWidth * 0.1,
                          child: _buildGuideMarker(),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          // "Position your face" label at the bottom of preview
          Positioned(
            bottom: 24,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Position face in the oval',
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuideMarker() {
    return Container(
      width: 6,
      height: 6,
      decoration: const BoxDecoration(
        color: Colors.greenAccent,
        shape: BoxShape.circle,
      ),
    );
  }

  Widget _buildPinStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Step 4: Secure PIN',
          style: GoogleFonts.poppins(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Set a 4-digit PIN for quick recognition login.',
          style: GoogleFonts.poppins(fontSize: 14, color: Colors.white54),
        ),
        const SizedBox(height: 48),
        Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Column(
              children: [
                TextField(
                  controller: _pinController,
                  obscureText: !_isPinVisible,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    fontSize: 32,
                    letterSpacing: 20,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: '0000',
                    hintStyle: TextStyle(
                      color: Colors.white10,
                      letterSpacing: 20,
                    ),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.blue, width: 2),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _isPinVisible ? Icons.visibility : Icons.visibility_off,
                        color: Colors.white38,
                      ),
                      onPressed: () {
                        setState(() => _isPinVisible = !_isPinVisible);
                      },
                    ),
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
                const SizedBox(height: 24),
                Text(
                  'This PIN can be used to punch attendance if biometrics fail or on devices without scanners.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    color: Colors.white38,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_statusMessage.isNotEmpty) _buildStatusText(),
      ],
    );
  }

  Widget _buildReviewAndComplete() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.blue.withOpacity(0.3)),
            ),
          ),
          child: Column(
            children: [
              const Icon(
                Icons.assignment_turned_in_rounded,
                size: 48,
                color: Colors.green,
              ),
              const SizedBox(height: 12),
              Text(
                'Enrollment Summary',
                style: GoogleFonts.poppins(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Text(
                'Please review details before final submission',
                style: GoogleFonts.poppins(fontSize: 14, color: Colors.white54),
              ),
            ],
          ),
        ),

        const SizedBox(height: 32),

        // Detailed Summary Card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            children: [
              _buildSummaryRow(
                Icons.person_rounded,
                'Employee',
                _selectedEmployee?.employeeName ?? 'N/A',
                Colors.blue,
              ),
              _buildSummaryRow(
                Icons.badge_rounded,
                'Employee ID',
                _selectedEmployee?.employeeId ?? 'N/A',
                Colors.blue,
              ),
              const Divider(color: Colors.white10, height: 32),
              _buildSummaryRow(
                Icons.fingerprint_rounded,
                'Biometric',
                _capturedFingerprints.isNotEmpty 
                    ? 'Fingerprint Captured (${_capturedFingerprints.length})' 
                    : (_selectedEmployee?.hasFingerprintEnrolled == true ? 'Existing Fingerprint' : 'Skipped/Not Enrolled'),
                _capturedFingerprints.isNotEmpty || _selectedEmployee?.hasFingerprintEnrolled == true 
                    ? Colors.purpleAccent 
                    : Colors.white24,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(
                    Icons.face_rounded,
                    size: 20,
                    color: Colors.orangeAccent,
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Face Photos',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const Spacer(),
                  Text(
                    _capturedImages.isEmpty &&
                            _selectedEmployee?.hasFaceEnrolled == true
                        ? 'Existing Data Reused'
                        : '${_capturedImages.length} Angle Photos',
                    style: TextStyle(
                      color:
                          _capturedImages.isEmpty &&
                              _selectedEmployee?.hasFaceEnrolled == true
                          ? Colors.orangeAccent
                          : Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const Divider(color: Colors.white10, height: 24),
              _buildSummaryRow(
                Icons.lock_rounded,
                'Security PIN',
                _pinController.text.isNotEmpty
                    ? 'New PIN Set'
                    : (_selectedEmployee?.hasPinEnrolled == true
                          ? 'Existing PIN Reused'
                          : 'Not Set'),
                _pinController.text.isNotEmpty ||
                        _selectedEmployee?.hasPinEnrolled == true
                    ? Colors.greenAccent
                    : Colors.white24,
              ),
              const SizedBox(height: 16),
              if (_capturedImages.isNotEmpty) _buildFaceThumbnails(),
            ],
          ),
        ),

        const SizedBox(height: 48),

        // Final Action
        SizedBox(
          height: 60,
          child: ElevatedButton(
            onPressed: _isEnrolling ? null : _enrollEmployee,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade600,
              foregroundColor: Colors.white,
              elevation: 8,
              shadowColor: Colors.green.withOpacity(0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: _isEnrolling
                ? const CircularProgressIndicator(color: Colors.white)
                : const Text(
                    'SUBMIT ENROLLMENT',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
          ),
        ),
        if (_statusMessage.isNotEmpty) _buildStatusText(),
      ],
    );
  }

  Widget _buildSummaryRow(
    IconData icon,
    String label,
    String value,
    Color iconColor,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(color: Colors.white70)),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationFooter() {
    if (!_isInitialized) return const SizedBox();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        border: const Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (_currentStep != EnrollmentStep.selectEmployee)
            TextButton.icon(
              onPressed: _isEnrolling ? null : _previousStep,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back'),
              style: TextButton.styleFrom(foregroundColor: Colors.white54),
            )
          else
            const SizedBox(width: 80),

          if (_currentStep != EnrollmentStep.complete)
            SizedBox(
              width: 140,
              height: 48,
              child: ElevatedButton(
                onPressed: _canGoNext() ? _nextStep : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade700,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.white.withOpacity(0.05),
                ),
                child: const Text('Next Step'),
              ),
            )
          else
            const SizedBox(width: 140),
        ],
      ),
    );
  }

  bool _canGoNext() {
    switch (_currentStep) {
      case EnrollmentStep.selectEmployee:
        return _selectedEmployee != null;
      case EnrollmentStep.fingerprint:
        // Allow always (admin can skip)
        return true;
      case EnrollmentStep.face:
        // Allow if captured newly OR already enrolled (for updates)
        return _allFaceCaptured || (_selectedEmployee?.hasFaceEnrolled == true);
      case EnrollmentStep.pin:
        // Optional step, but if they started typing it should be 4 digits is not strictly needed here
        // as _nextStep handles validation, but good for button disabling.
        return _pinController.text.isEmpty || _pinController.text.length == 4;
      case EnrollmentStep.complete:
        return false;
    }
  }

  // --- Helper Widgets ---

  Widget _buildEmployeeCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blue.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Text(
            _selectedEmployee!.employeeName,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
          Text(
            'ID: ${_selectedEmployee!.employeeId}',
            style: const TextStyle(color: Colors.white54),
          ),
          if (_selectedEmployee!.department != null)
            Text(
              _selectedEmployee!.department!,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _buildFaceThumbnails() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: _capturedImages
              .map(
                (bytes) => ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    bytes,
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                  ),
                ),
              )
              .toList(),
        ),
        if (_currentStep == EnrollmentStep.face)
          TextButton(
            onPressed: () => setState(() => _capturedImages.clear()),
            child: const Text('Retake Photos'),
          ),
      ],
    );
  }

  Widget _buildStatusText() {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Text(
        _statusMessage,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: _statusMessage.contains('✅') ? Colors.green : Colors.redAccent,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          const Icon(Icons.group_off_rounded, size: 48, color: Colors.orange),
          const SizedBox(height: 16),
          const Text(
            'No Employees Found',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Check your network connection or server URL. If you are using Production, the server might be down (502).',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _fetchEmployees,
            child: const Text('Retry Fetch'),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return const Center(child: CircularProgressIndicator());
  }
}

/// CustomPainter that draws a dark overlay with an oval cutout for face positioning
class _FaceOvalMaskPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withOpacity(0.55)
      ..style = PaintingStyle.fill;

    // Draw full dark overlay
    final fullRect = Rect.fromLTWH(0, 0, size.width, size.height);

    // Create oval cutout in center
    // Use the shortest side to determine the base size so it doesn't stretch
    final shortSide = size.width < size.height ? size.width : size.height;

    final ovalWidth = shortSide * 0.65;
    final ovalHeight = shortSide * 0.8; // Always taller than wide

    final ovalRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: ovalWidth,
      height: ovalHeight,
    );

    // Use Path to cut out the oval from the full rect
    final path = Path()
      ..addRect(fullRect)
      ..addOval(ovalRect);
    path.fillType = PathFillType.evenOdd;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
