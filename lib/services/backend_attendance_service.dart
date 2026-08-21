import 'dart:convert';
import 'dart:typed_data';
import '../api/backend_api.dart';
import 'face_embedding_service.dart';
import 'fingerprint_service.dart';

/// Attendance service using backend API
/// Replaces local SQLite with Webnox Sprintly backend
class BackendAttendanceService {
  final BackendApi _api;
  final FaceEmbeddingService _faceEmbeddingService;
  final FingerprintService _fingerprintService;

  // Cached employees for faster matching
  List<EmployeeEmbedding>? _cachedEmployees;
  DateTime? _lastCacheTime;
  static const _cacheDuration = Duration(minutes: 5);

  BackendAttendanceService(
    this._api,
    this._faceEmbeddingService,
    this._fingerprintService,
  );

  // Cache for punch cooldown to prevent double punches
  final Map<String, DateTime> _lastPunchTimes = {};
  static const _punchCooldown = Duration(minutes: 1);

  /// Refresh employee cache from backend
  Future<void> refreshEmployeeCache() async {
    try {
      print('🔄 Refreshing employee cache from backend...');
      _cachedEmployees = await _api.getAllEnrolledEmployees();
      _lastCacheTime = DateTime.now();

      print('✅ Cache refreshed. Loaded ${_cachedEmployees?.length} employees:');
      for (final e in _cachedEmployees ?? []) {
        print(
          '   - ${e.employeeName} (ID: ${e.employeeId}, EmbSize: ${e.embedding.length})',
        );
      }
    } catch (e) {
      print('❌ Failed to refresh employee cache: $e');
      if (_cachedEmployees == null)
        rethrow; // Keep old cache if possible? No, rethrow if null.
    }
  }

  /// Get enrolled employees (with cache)
  Future<List<EmployeeEmbedding>> getEnrolledEmployees() async {
    // Force refresh if null
    if (_cachedEmployees == null) {
      await refreshEmployeeCache();
    }
    return _cachedEmployees ?? [];
  }

  /// Check if employee is enrolled
  Future<bool> isEmployeeEnrolled(String employeeId) async {
    final employees = await getEnrolledEmployees();
    return employees.any((e) => e.employeeId == employeeId);
  }

  /// Enroll a new employee (Fingerprint or Face)
  Future<bool> enrollEmployee({
    required String employeeId,
    required String name,
    String? department,
    String? fingerprintTemplate,
    String? pin,
    List<Uint8List>? faceImages,
    List<Map<String, int>>? faceRects,
    String? existingEmbedding,
    String? existingFingerprintTemplate,
    String? existingPin,
  }) async {
    String? embeddingStr = existingEmbedding;

    // Generate averaged face embedding if images provided
    if (faceImages != null && faceImages.isNotEmpty) {
      final embedding = await _faceEmbeddingService.getAveragedEmbedding(
        faceImages,
        faceRects: faceRects,
      );
      // Convert embedding to comma-separated string for backend
      embeddingStr = embedding.map((e) => e.toStringAsFixed(8)).join(',');
    }

    // Use new values if provided, otherwise fallback to existing
    final finalFingerprint = fingerprintTemplate ?? existingFingerprintTemplate;
    final finalPin = pin ?? existingPin;

    // Send to backend (Face + Fingerprint + PIN)
    final success = await _api.enrollFace(
      employeeId: employeeId,
      embedding: embeddingStr,
      fingerprintTemplate: finalFingerprint,
      pin: finalPin,
      department: department,
      enrolledBy: 'kiosk_admin',
    );

    if (success) {
      await refreshEmployeeCache();
    }

    return success;
  }

  /// Verify employee PIN
  Future<AttendanceResult> verifyPin(String pin) async {
    print('');
    print('╔════════════════════════════════════════════════════════════╗');
    print('║              PIN VERIFICATION DEBUG LOG                    ║');
    print('╠════════════════════════════════════════════════════════════╣');
    print('║ PIN Entered: ${'*' * pin.length}'); // Masked for security
    print('╠════════════════════════════════════════════════════════════╣');

    try {
      print('🔍 Verifying PIN via backend...');
      final result = await _api.verifyPin(pin: pin);

      if (result['success'] == true) {
        final data = result['data'] as Map<String, dynamic>?;
        // Backend may return snake_case or camelCase; support both
        final empId =
            (data?['employee_id'] ?? data?['employeeId'])?.toString() ?? '';
        final empName = (data?['employee_name'] ?? data?['employeeName'])
            ?.toString();

        if (empId.trim().isEmpty) {
          print('║ ❌ RESULT: PIN OK, BUT DATA MISSING');
          print('║    Response: $data');
          print(
            '╚════════════════════════════════════════════════════════════╝',
          );
          print('');
          return AttendanceResult.error('PIN verified but employee not found');
        }

        print('║ ✅ RESULT: PIN MATCHED');
        print('║    Candidate: $empName ($empId)');
        print('╚════════════════════════════════════════════════════════════╝');
        print('');

        // Decide IN vs OUT and perform punch
        return await punchByEmployeeId(
          empId,
          100.0, // PIN gives 100% confidence
          employeeName: empName,
        );
      } else {
        final msg = result['message'] ?? 'Invalid PIN';
        print('║ ❌ RESULT: INVALID PIN');
        print('║    Message: $msg');
        print('╚════════════════════════════════════════════════════════════╝');
        print('');
        return AttendanceResult.error(msg);
      }
    } catch (e) {
      print('║ ❌ RESULT: ERROR');
      print('║    Details: $e');
      print('╚════════════════════════════════════════════════════════════╝');
      print('');
      return AttendanceResult.error('Error verifying PIN: $e');
    }
  }

  /// Match fingerprint and record attendance
  /// This implements Client-Side Identification + Smart Punch Toggle
  Future<AttendanceResult> punchAttendance(String capturedTemplate) async {
    try {
      print('🔍 Starting punch process (Client-Side Logic)...');

      // 1. IDENTIFY: Find the person locally first
      // This allows us to know WHO it is before deciding WHAT to do (IN vs OUT)
      final employees = await getEnrolledEmployees();
      final localMatch = await _findBestFingerprintMatch(
        capturedTemplate,
        employees,
      );

      if (localMatch != null) {
        print(
          '✅ Local match found: ${localMatch.employeeName} (${localMatch.employeeId})',
        );

        // 2. SMART PUNCH: Check status and toggle IN/OUT
        return await punchByEmployeeId(
          localMatch.employeeId,
          localMatch.confidence,
          employeeName: localMatch.employeeName,
        );
      } else {
        print('❌ No local match found for fingerprint.');

        // Optional: We could fallback to server-side verify if local fails,
        // but for consistent punch logic, we should rely on local ID.
        // Uncomment below if you still want server-side fallback for ID only.
        /*
        final serverResult = await _api.verifyFingerprint(capturedTemplate: capturedTemplate);
        if (serverResult['success'] == true) {
           // ... handle server match ...
        }
        */

        return AttendanceResult.error('Fingerprint not recognized');
      }
    } catch (e) {
      print('❌ Punch error: $e');
      return AttendanceResult.error('Error processing punch: $e');
    }
  }

  /// Match face and record attendance
  /// This implements the complete biometric flow using averaged embeddings
  Future<AttendanceResult> punchFaceAttendance(
    List<Uint8List> faceImages, {
    List<Map<String, int>>? faceRects,
  }) async {
    try {
      print('🔍 Starting face punch process (Averaged Embedding)...');

      // 1. Get averaged embedding from images (Denoising)
      final embedding = await _faceEmbeddingService.getAveragedEmbedding(
        faceImages,
        faceRects: faceRects,
      );

      // 2. IDENTIFY: Find the person
      final employees = await getEnrolledEmployees();
      final match = _findBestFaceMatch(embedding, employees);

      if (match != null) {
        print(
          '✅ Face match found: ${match.employeeName} (${match.employeeId})',
        );

        // 3. SMART PUNCH: Check status and toggle IN/OUT
        return await punchByEmployeeId(
          match.employeeId,
          match.confidence,
          employeeName: match.employeeName,
        );
      } else {
        print('❌ No face match found.');
        return AttendanceResult.error('Face not recognized');
      }
    } catch (e) {
      print('❌ Face punch error: $e');
      return AttendanceResult.error('Error processing face punch: $e');
    }
  }

  /// Get a specific employee's details (retrying with cache refresh if needed)
  Future<EmployeeEmbedding?> getEmployeeDetails(String employeeId) async {
    // 1. Try local cache first
    try {
      if (_cachedEmployees != null && _cachedEmployees!.isNotEmpty) {
        return _cachedEmployees!.firstWhere((e) => e.employeeId == employeeId);
      }
    } catch (_) {
      // Not found in current cache
    }

    // 2. If not found or cache empty, force refresh
    print('⚠️ Employee $employeeId not found in cache. Refreshing...');
    await refreshEmployeeCache();

    // 3. Try again after refresh
    try {
      if (_cachedEmployees != null) {
        return _cachedEmployees!.firstWhere((e) => e.employeeId == employeeId);
      }
    } catch (_) {
      print('❌ Employee $employeeId not found even after refresh.');
      return null;
    }
    return null;
  }

  /// Match face ONLY (no punch) - for confirmation flow
  /// Returns MatchResult if face is recognized, null if not
  Future<MatchResult?> matchFaceOnly(
    Uint8List faceImage, {
    Map<String, int>? faceRect,
  }) async {
    // Generate embedding for the captured face
    final embedding = await _faceEmbeddingService.getEmbedding(
      faceImage,
      faceRect: faceRect,
    );

    // Get enrolled employees (uses cache)
    final employees = await getEnrolledEmployees();
    if (employees.isEmpty) {
      throw Exception(
        'No enrolled employees found. Please check server connection.',
      );
    }

    // Find best match
    return _findBestFaceMatch(embedding, employees);
  }

  /// Punch by employee ID (after user confirmation)
  Future<AttendanceResult> punchByEmployeeId(
    String employeeId,
    double matchConfidence, {
    String? employeeName,
  }) async {
    // 1. Check Cooldown
    final lastTime = _lastPunchTimes[employeeId];
    if (lastTime != null) {
      final difference = DateTime.now().difference(lastTime);
      if (difference < _punchCooldown) {
        final remaining = _punchCooldown.inSeconds - difference.inSeconds;
        print('⏳ Punch prevented by cooldown: $remaining s');
        return AttendanceResult.error(
          'Already punched. Please wait ${remaining}s.',
          employeeCode: employeeId,
          employeeName: employeeName,
        );
      }
    }

    // 2. Fetch today's attendance to determine IN vs OUT logic
    print('🔍 Determining punch type (IN/OUT) for $employeeId...');
    String punchType = 'IN'; // Default to IN
    try {
      final now = DateTime.now();
      final dateStr = now.toIso8601String().substring(0, 10);
      print('🔍 Checking attendance for Date: $dateStr');

      // Get all records for today
      final records = await _api.getEmployeeAttendanceByDate(
        employeeId,
        dateStr,
      );
      print('🔍 Records found count: ${records.length}');
      if (records.isNotEmpty) {
        print(
          '   Last Record: On=${records.last.clockOnTime}, Off=${records.last.clockOffTime}',
        );
      }

      if (records.isNotEmpty) {
        // Robust Check: Look for ANY active session (clock_in != null AND clock_out == null)
        // This matches the Employee Frontend logic exactly.
        final activeSession = records.any(
          (r) =>
              r.clockOnTime != null &&
              r.clockOnTime!.isNotEmpty &&
              (r.clockOffTime == null || r.clockOffTime!.isEmpty),
        );

        if (activeSession) {
          print('✅ Found active session -> Switching to PUNCH OUT');
          punchType = 'OUT';
        } else {
          print('ℹ️ No active session found -> Switching to PUNCH IN');
          punchType = 'IN';
        }
      } else {
        print('ℹ️ No records for today -> PUNCH IN');
        punchType = 'IN';
      }
    } catch (e) {
      print('Error determining punch type: $e');
      // Fallback: If network fails, we might defaulting to IN, or maybe error out?
      // Ideally we should warn the user, but for now defaulting to IN is standard behavior.
      punchType = 'IN';
    }

    // 3. Perform Punch with Explicit Type
    print('🚀 Executing punch: Type=$punchType, PID=$employeeId');
    final result = await _api.punchAttendance(
      employeeId: employeeId,
      punchType: punchType,
      matchConfidence: matchConfidence,
    );

    if (result.success) {
      // 2. Update Cooldown on success
      _lastPunchTimes[employeeId] = DateTime.now();

      return AttendanceResult.success(
        employeeCode: employeeId,
        employeeName: employeeName ?? '',
        punchType: result.punchType,
        confidence: matchConfidence,
        timestamp: DateTime.now(),
        message: result.message,
      );
    } else {
      print('❌ Punch API failed: ${result.message}');
      return AttendanceResult.error(result.message);
    }
  }

  /// Match fingerprint ONLY (no punch) - for confirmation flow
  /// This still uses server-side verification but expects a different handling
  Future<MatchResult?> matchFingerprint(String capturedTemplate) async {
    try {
      final employees = await getEnrolledEmployees();
      if (employees.isEmpty) return null;

      return await _findBestFingerprintMatch(capturedTemplate, employees);
    } catch (e) {
      print('matchFingerprint error: $e');
      return null;
    }
  }

  /// Find matching employee for a fingerprint (Legacy local match - unused in Option A)
  Future<MatchResult?> _findBestFingerprintMatch(
    String capturedTemplate,
    List<EmployeeEmbedding> employees,
  ) async {
    print('');
    print('╔════════════════════════════════════════════════════════════╗');
    print('║        FINGERPRINT MATCHING DEBUG LOG                      ║');
    print('╠════════════════════════════════════════════════════════════╣');
    print('║ Comparing against ${employees.length} enrolled employees');
    print('╠════════════════════════════════════════════════════════════╣');

    MatchResult? bestMatch;
    int highestScore = 0;

    for (final employee in employees) {
      if (employee.fingerprintTemplate == null ||
          employee.fingerprintTemplate!.isEmpty) {
        continue;
      }

      // Call the fingerprint service to match
      try {
        List<int> t1 = base64Decode(capturedTemplate);
        List<String> templatesToMatch = [];
        
        try {
          final decoded = jsonDecode(employee.fingerprintTemplate!);
          if (decoded is List) {
            templatesToMatch = decoded.map((e) => e.toString()).toList();
          } else {
            templatesToMatch = [employee.fingerprintTemplate!];
          }
        } catch (_) {
          // Fallback to legacy single template
          templatesToMatch = [employee.fingerprintTemplate!];
        }

        int maxScoreForEmployee = 0;
        for (final tmpl in templatesToMatch) {
          try {
            List<int> t2 = base64Decode(tmpl);
            final score = await _fingerprintService.match(t1, t2);
            if (score > maxScoreForEmployee) {
              maxScoreForEmployee = score;
            }
          } catch (e) {
             print('Error matching one of the templates: $e');
          }
        }

        if (maxScoreForEmployee > highestScore) {
          highestScore = maxScoreForEmployee;
          bestMatch = MatchResult(
            employeeId: employee.employeeId,
            employeeName: employee.employeeName,
            confidence: maxScoreForEmployee.toDouble(),
            lastPunchType: 'OUT', // Default
          );
        }
      } catch (e) {
        print('Error matching template for ${employee.employeeName}: $e');
      }
    }

    // Lowered threshold to 700 based on field testing (scores ~700-800)
    // This maintains usability while avoiding trivial false positives (<100)
    if (highestScore >= 700) {
      print('║ ✅ RESULT: MATCHED ${bestMatch?.employeeName}');
      print('║    Score: $highestScore (threshold: 700)');
      print('╚════════════════════════════════════════════════════════════╝');
      print('');
      return bestMatch;
    }

    print('║ ❌ RESULT: NO MATCH FOUND');
    print('║    Best score: $highestScore (threshold: 700)');
    if (bestMatch != null) {
      print('║    Best candidate: ${bestMatch.employeeName}');
    }
    print('╚════════════════════════════════════════════════════════════╝');
    print('');
    return null;
  }

  /// Find the best matching employee for a face embedding
  MatchResult? _findBestFaceMatch(
    List<double> embedding,
    List<EmployeeEmbedding> employees,
  ) {
    double bestScore = 0;
    double secondBestScore = 0;
    EmployeeEmbedding? bestMatch;
    String? secondBestName;

    // Minimum gap between #1 and #2 to avoid ambiguous matches
    const double minGap = 0.05; // 5%

    print('');
    print('╔════════════════════════════════════════════════════════════╗');
    print('║           FACE MATCHING DEBUG LOG                         ║');
    print('╠════════════════════════════════════════════════════════════╣');
    print('║ Comparing against ${employees.length} enrolled employees');
    print('║ Match Threshold: 53% | Min Gap: 5%');
    print('╠════════════════════════════════════════════════════════════╣');

    for (final employee in employees) {
      if (employee.embedding.isEmpty) {
        print('║ ⚠️ Skipping ${employee.employeeName} (No embedding)');
        continue;
      }

      final score = _faceEmbeddingService.cosineSimilarity(
        embedding,
        employee.embedding,
      );

      print(
        '║ - ${employee.employeeName}: ${(score * 100).toStringAsFixed(1)}%',
      );

      if (score > bestScore) {
        // Current best becomes second best
        secondBestScore = bestScore;
        secondBestName = bestMatch?.employeeName;
        // New best
        bestScore = score;
        bestMatch = employee;
      } else if (score > secondBestScore) {
        secondBestScore = score;
        secondBestName = employee.employeeName;
      }
    }

    print('╠════════════════════════════════════════════════════════════╣');

    // Threshold check (55% for match)
    if (bestScore < 0.53 || bestMatch == null) {
      print('║ ❌ RESULT: NO MATCH FOUND');
      print(
        '║    Best score: ${(bestScore * 100).toStringAsFixed(1)}% (below 53% threshold)',
      );
      print('╚════════════════════════════════════════════════════════════╝');
      print('');
      return null;
    }

    // Ambiguity check: reject if top two are too close
    final gap = bestScore - secondBestScore;
    if (gap < minGap && secondBestScore > 0.50) {
      print('║ ⚠️ RESULT: AMBIGUOUS MATCH - TOO CLOSE');
      print(
        '║    #1: ${bestMatch.employeeName} = ${(bestScore * 100).toStringAsFixed(1)}%',
      );
      print(
        '║    #2: ${secondBestName ?? "?"} = ${(secondBestScore * 100).toStringAsFixed(1)}%',
      );
      print(
        '║    Gap: ${(gap * 100).toStringAsFixed(1)}% (need ${(minGap * 100).toStringAsFixed(0)}%)',
      );
      print('╚════════════════════════════════════════════════════════════╝');
      print('');
      return null;
    }

    print('║ ✅ RESULT: MATCHED ${bestMatch.employeeName}');
    print('║    Confidence: ${(bestScore * 100).toStringAsFixed(1)}%');
    if (secondBestName != null) {
      print(
        '║    Runner-up: $secondBestName = ${(secondBestScore * 100).toStringAsFixed(1)}% (gap: ${(gap * 100).toStringAsFixed(1)}%)',
      );
    }
    print('╚════════════════════════════════════════════════════════════╝');
    print('');

    return MatchResult(
      employeeId: bestMatch.employeeId,
      employeeName: bestMatch.employeeName,
      confidence: bestScore * 100,
      lastPunchType: 'OUT',
    );
  }

  Future<List<EmployeeForEnrollment>> getEmployeesForEnrollment() async {
    return await _api.getEmployeesForEnrollment();
  }

  Future<bool> deleteEnrollment(String employeeId) async {
    final success = await _api.deleteFaceEnrollment(employeeId);
    if (success) {
      await refreshEmployeeCache();
    }
    return success;
  }

  void dispose() {
    // _api.dispose(); // Removed: BackendApi is a singleton
  }
}

/// Result of face matching
class MatchResult {
  final String employeeId;
  final String employeeName;
  final double confidence;
  final String lastPunchType;

  MatchResult({
    required this.employeeId,
    required this.employeeName,
    required this.confidence,
    required this.lastPunchType,
  });
}

/// Result of attendance punch
class AttendanceResult {
  final bool success;
  final String? employeeCode;
  final String? employeeName;
  final String? punchType;
  final double? confidence;
  final DateTime? timestamp;
  final String? message;
  final String? error;

  AttendanceResult._({
    required this.success,
    this.employeeCode,
    this.employeeName,
    this.punchType,
    this.confidence,
    this.timestamp,
    this.message,
    this.error,
  });

  factory AttendanceResult.success({
    required String employeeCode,
    required String employeeName,
    required String punchType,
    required double confidence,
    required DateTime timestamp,
    String? message,
  }) {
    return AttendanceResult._(
      success: true,
      employeeCode: employeeCode,
      employeeName: employeeName,
      punchType: punchType,
      confidence: confidence,
      timestamp: timestamp,
      message: message,
    );
  }

  factory AttendanceResult.error(
    String message, {
    String? employeeCode,
    String? employeeName,
  }) {
    return AttendanceResult._(
      success: false,
      error: message,
      employeeCode: employeeCode,
      employeeName: employeeName,
    );
  }
}
