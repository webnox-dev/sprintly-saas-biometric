import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Backend API client for biometric kiosk
/// Connects to Webnox Sprintly backend for employee data and attendance
class BackendApi {
  // Singleton Pattern
  static final BackendApi _instance = BackendApi._internal();
  factory BackendApi() => _instance;
  BackendApi._internal() {
    _loadSavedConfig();
  }

  // Backend base URL - Matches Employee & Admin dashboard
  static const String liveBaseUrl = 'https://api.rathz.com/api';
  static const String localBaseUrl = 'http://localhost:8080/api';
  
  // Active base URL (defaults to live SaaS API like employee dashboard)
  static String _activeBaseUrl = liveBaseUrl;

  static String get baseUrl => _activeBaseUrl;

  /// Set custom base URL if running local server or different environment
  static void setBaseUrl(String url) {
    _activeBaseUrl = url;
  }

  final http.Client _client = http.Client();
  String? _authToken;
  String? _organizationId;

  Future<void> _loadSavedConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedOrg = prefs.getString('kiosk_organization_id');
      if (savedOrg != null && savedOrg.isNotEmpty) {
        _organizationId = savedOrg;
      }
    } catch (_) {}
  }

  /// Set organization ID for multi-tenant kiosk and persist to disk
  Future<void> setOrganizationId(String? orgId) async {
    _organizationId = orgId;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (orgId != null && orgId.isNotEmpty) {
        await prefs.setString('kiosk_organization_id', orgId);
      } else {
        await prefs.remove('kiosk_organization_id');
      }
    } catch (_) {}
  }

  String? get organizationId => _organizationId;

  /// Fetch organization name from backend by organization ID
  Future<String?> fetchOrganizationName(String orgId) async {
    try {
      final response = await _client
          .get(
            Uri.parse('$baseUrl/public/organization/$orgId'),
            headers: {'Content-Type': 'application/json', 'X-Organization-Id': orgId},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['data'] != null) {
          final name = data['data']['display_name'] ?? data['data']['organization_name'] ?? data['data']['name'];
          if (name != null && name.toString().isNotEmpty) {
            return name.toString();
          }
        }
      }
    } catch (e) {
      print('⚠️ BackendApi.fetchOrganizationName error: $e');
    }
    return null;
  }

  // Common headers
  Map<String, String> get _headers {
    final headers = {'Content-Type': 'application/json'};
    if (_authToken != null) {
      headers['Authorization'] = 'Bearer $_authToken';
    }
    if (_organizationId != null && _organizationId!.isNotEmpty) {
      headers['X-Organization-Id'] = _organizationId!;
    }
    return headers;
  }

  /// Get all enrolled employees with face embeddings
  Future<List<EmployeeEmbedding>> getAllEnrolledEmployees() async {
    try {
      print('🌐 BackendApi: Requesting GET $baseUrl/face/employees');
      final response = await _client
          .get(Uri.parse('$baseUrl/face/employees'), headers: _headers)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final employees = (data['data']['employees'] as List)
              .map((e) => EmployeeEmbedding.fromJson(e))
              .toList();
          print('✅ BackendApi: Loaded ${employees.length} employees');
          return employees;
        }
      }
      print(
        '❌ BackendApi: Status ${response.statusCode}, Body: ${response.body}',
      );
      throw Exception('Failed to get enrolled employees: ${response.body}');
    } catch (e) {
      print('⚠️ BackendApi.getAllEnrolledEmployees error: $e');
      if (e.toString().contains('127.0.0.1') ||
          e.toString().contains('localhost')) {
        print('💡 HINT: You are using "localhost" on an Android device.');
        print('   - If using Emulator, use: http://10.0.2.2:8080/api');
        print(
          '   - If using Real Device, use your PC IP: http://192.168.x.x:8080/api',
        );
      }
      rethrow;
    }
  }

  /// Get all employees for enrollment UI (includes non-enrolled)
  Future<List<EmployeeForEnrollment>> getEmployeesForEnrollment() async {
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/face/employees-for-enrollment'),
        headers: _headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final employees = (data['data']['employees'] as List)
              .map((e) => EmployeeForEnrollment.fromJson(e))
              .toList();
          return employees;
        }
      }
      throw Exception('Failed to get employees: ${response.body}');
    } catch (e) {
      print('BackendApi.getEmployeesForEnrollment error: $e');
      rethrow;
    }
  }

  /// Enroll face/fingerprint for an employee
  Future<bool> enrollFace({
    required String employeeId,
    String? embedding,
    String? fingerprintTemplate,
    String? pin,
    String? department,
    String? enrolledBy,
  }) async {
    final payload = {
      'employee_id': employeeId,
      'embedding': embedding != null
          ? '${embedding.substring(0, 20)}...'
          : null,
      'fingerprint_template': fingerprintTemplate != null
          ? '${fingerprintTemplate.substring(0, 20)}...'
          : null,
      'pin': pin != null ? '****' : null,
      'department': department,
      'enrolled_by': enrolledBy,
    };

    try {
      print('🌐 BackendApi: Enrolling biometric data for $employeeId');
      print('📦 Payload Sample: ${jsonEncode(payload)}');
      print('📦 Full Fingerprint Length: ${fingerprintTemplate?.length ?? 0}');

      final response = await _client
          .post(
            Uri.parse('$baseUrl/face/enroll'),
            headers: _headers,
            body: jsonEncode({
              'employee_id': employeeId,
              'embedding': embedding,
              'fingerprint_template': fingerprintTemplate,
              'pin': pin,
              'department': department,
              'enrolled_by': enrolledBy,
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 201 || response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('✅ BackendApi: Enrollment successful');
        return data['success'] == true;
      }

      print(
        '❌ BackendApi: Enrollment failed with status ${response.statusCode}',
      );
      if (response.statusCode == 502) {
        print(
          '💡 HINT: 502 Bad Gateway means the server at $baseUrl is likely DOWN or its proxy is misconfigured.',
        );
      }

      throw Exception(
        'Failed to enroll biometric data: error code: ${response.statusCode}',
      );
    } catch (e) {
      print('⚠️ BackendApi.enrollFace error: $e');
      rethrow;
    }
  }

  /// Punch in/out via face recognition
  Future<PunchResult> punchAttendance({
    required String employeeId,
    required String punchType, // 'IN' or 'OUT'
    double? matchConfidence,
  }) async {
    try {
      // Use ISO 8601 format
      final now = DateTime.now();
      String clockTimestamp = now.toIso8601String();

      // Ensure it has a timezone offset if missing (e.g. Android sometimes omits it)
      if (!clockTimestamp.endsWith('Z') &&
          !clockTimestamp.contains('+') &&
          !clockTimestamp.contains('-')) {
        final offset = now.timeZoneOffset;
        final hours = offset.inHours;
        final minutes = (offset.inMinutes % 60).abs();
        final sign = hours >= 0 ? '+' : '-';
        final offsetStr =
            '$sign${hours.abs().toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}';
        clockTimestamp = '$clockTimestamp$offsetStr';
      }

      print('Biometric punch - Timestamp: $clockTimestamp');

      final response = await _client
          .post(
            Uri.parse('$baseUrl/face/punch'),
            headers: _headers,
            body: jsonEncode({
              'employee_id': employeeId,
              'punch_type': punchType,
              'match_confidence': matchConfidence,
              'clock_timestamp': clockTimestamp,
            }),
          )
          .timeout(const Duration(seconds: 15));
      ;

      print('Backend Response (${response.statusCode}): ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          return PunchResult(
            success: true,
            message: data['message'] ?? 'Success',
            punchType: data['data']?['punch_type'] ?? punchType,
            attendanceId: data['data']?['attendance_id'],
            sessionDuration: data['data']?['session_duration'],
          );
        }
      }

      // Handle non-JSON responses (like 502 Bad Gateway HTML)
      if (response.body.trim().startsWith('<')) {
        return PunchResult(
          success: false,
          message: 'Server Error (${response.statusCode}): Bad Gateway',
          punchType: punchType,
        );
      }

      final data = jsonDecode(response.body);
      return PunchResult(
        success: false,
        message: data['error']?['message'] ?? data['message'] ?? 'Punch failed',
        punchType: punchType,
      );
    } catch (e) {
      print('BackendApi.punchAttendance error: $e');
      return PunchResult(
        success: false,
        message: 'Network error: $e',
        punchType: punchType,
      );
    }
  }

  /// Verify fingerprint and record attendance (Server-side match)
  Future<Map<String, dynamic>> verifyFingerprint({
    required String capturedTemplate,
  }) async {
    try {
      final now = DateTime.now();
      String clockTimestamp = now.toIso8601String();

      // Ensure timezone offset is included
      if (!clockTimestamp.endsWith('Z') &&
          !RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(clockTimestamp)) {
        final offset = now.timeZoneOffset;
        final hours = offset.inHours;
        final minutes = offset.inMinutes.abs() % 60;
        final offsetString =
            '${hours >= 0 ? '+' : '-'}${hours.abs().toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}';
        clockTimestamp = clockTimestamp + offsetString;
      }

      final fullUrl = '$baseUrl/face/verify-fingerprint';
      final payload = {
        'captured_template': capturedTemplate,
        'clock_timestamp': clockTimestamp,
      };

      print('🚀 BackendApi.verifyFingerprint: POST $fullUrl');
      print('📦 Full JSON Payload: ${jsonEncode(payload)}');
      print('📏 Total Payload Length: ${jsonEncode(payload).length}');

      final response = await _client
          .post(
            Uri.parse(fullUrl),
            headers: _headers,
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      print('📡 Response Status: ${response.statusCode}');
      print('📡 Response Headers: ${response.headers}');
      print('📄 Raw Response Body: ${response.body}');

      // Check if response is JSON to avoid FormatException
      final contentType = response.headers['content-type'] ?? '';
      if (!contentType.contains('application/json')) {
        print('❌ BackendApi: Received non-JSON response from $fullUrl');

        if (response.statusCode == 404) {
          return {
            'success': false,
            'message': 'API route not found. Full URL called: $fullUrl',
          };
        }
        return {
          'success': false,
          'message': 'Server error: ${response.statusCode}',
        };
      }

      final data = jsonDecode(response.body);
      print('📦 Decoded Response Data: $data');

      if (response.statusCode == 200 || response.statusCode == 201) {
        return data;
      } else {
        return {
          'success': false,
          'message':
              data['error']?['message'] ??
              data['message'] ??
              'Identity not recognized',
        };
      }
    } catch (e) {
      print('⚠️ BackendApi.verifyFingerprint error: $e');
      if (e is FormatException && e.toString().contains('Route not found')) {
        return {
          'success': false,
          'message':
              'Server says: Route not found. Please check if your backend is updated and running.',
        };
      }
      return {'success': false, 'message': 'Network error: $e'};
    }
  }

  /// Verify employee PIN
  Future<Map<String, dynamic>> verifyPin({
    String? employeeId,
    required String pin,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/face/verify-pin'),
            headers: _headers,
            body: jsonEncode({
              if (employeeId != null) 'employeeId': employeeId,
              'pin': pin,
            }),
          )
          .timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);
      if (response.statusCode == 200) {
        return {
          'success': true,
          'message': data['message'] ?? 'PIN verified',
          'data': data['data'],
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'PIN verification failed',
        };
      }
    } catch (e) {
      print('BackendApi.verifyPin error: $e');
      return {'success': false, 'message': 'Network error: $e'};
    }
  }

  /// Check if a PIN is available (not used by another employee)
  Future<bool> checkPinAvailable({
    required String pin,
    String? excludeEmployeeId,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/face/check-pin'),
            headers: _headers,
            body: jsonEncode({
              'pin': pin,
              if (excludeEmployeeId != null)
                'exclude_employee_id': excludeEmployeeId,
            }),
          )
          .timeout(const Duration(seconds: 10));

      // Handle non-JSON responses (404 HTML, 502 Bad Gateway, etc.)
      final contentType = response.headers['content-type'] ?? '';
      if (!contentType.contains('application/json')) {
        print(
          '⚠️ checkPinAvailable: Non-JSON response (${response.statusCode})',
        );
        // Fallback: use verifyPin to check if PIN exists
        return await _fallbackPinCheck(pin, excludeEmployeeId);
      }

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        return data['data']['available'] == true;
      }
      return false;
    } catch (e) {
      print('BackendApi.checkPinAvailable error: $e');
      // Fallback: use verifyPin to check if PIN exists
      return await _fallbackPinCheck(pin, excludeEmployeeId);
    }
  }

  /// Fallback PIN check using verifyPin endpoint
  Future<bool> _fallbackPinCheck(String pin, String? excludeEmployeeId) async {
    try {
      final result = await verifyPin(pin: pin);
      if (result['success'] == true) {
        // PIN exists — check if it belongs to the same employee
        final matchedId = result['data']?['employee_id']?.toString();
        if (excludeEmployeeId != null && matchedId == excludeEmployeeId) {
          return true; // Same employee's own PIN — available
        }
        return false; // PIN taken by someone else
      }
      return true; // PIN not found = available
    } catch (e) {
      print('_fallbackPinCheck error: $e');
      return true; // If all checks fail, allow enrollment (backend will validate)
    }
  }

  /// Delete face enrollment
  Future<bool> deleteFaceEnrollment(String employeeId) async {
    try {
      final response = await _client.delete(
        Uri.parse('$baseUrl/face/employees/$employeeId'),
        headers: _headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['success'] == true;
      }
      return false;
    } catch (e) {
      print('BackendApi.deleteFaceEnrollment error: $e');
      return false;
    }
  }

  /// Get today's attendance for all employees
  Future<List<AttendanceRecord>> getTodayAttendance() async {
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/attendance/today'),
        headers: _headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final attendances = (data['data'] as List? ?? [])
              .map((e) => AttendanceRecord.fromJson(e))
              .toList();
          return attendances;
        }
      }
      return [];
    } catch (e) {
      print('BackendApi.getTodayAttendance error: $e');
      return [];
    }
  }

  /// Get attendance for a specific employee on a specific date
  Future<List<AttendanceRecord>> getEmployeeAttendanceByDate(
    String employeeId,
    String date,
  ) async {
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/attendance/employee/$employeeId/date/$date'),
        headers: _headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final attendances = (data['data'] as List? ?? [])
              .map((e) => AttendanceRecord.fromJson(e))
              .toList();
          return attendances;
        }
      }
      return [];
    } catch (e) {
      print('BackendApi.getEmployeeAttendanceByDate error: $e');
      return [];
    }
  }

  /// Verify admin credentials via backend login
  Future<bool> verifyAdmin(String email, String password) async {
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/auth/login'),
        headers: _headers,
        body: jsonEncode({
          'email': email,
          'password': password,
          'role': 'Admin',
        }),
      );

      print('Admin verification response: ${response.statusCode}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);

        // Check for success flag or token presence
        if (data['success'] == true || data['token'] != null) {
          // SAVE TOKEN for future requests
          if (data['token'] != null) {
            _authToken = data['token'];
            print('✅ Admin Login Successful. Token Saved.');
          } else if (data['data'] != null && data['data']['token'] != null) {
            _authToken = data['data']['token'];
            print('✅ Admin Login Successful (nested). Token Saved.');
          }
          return true;
        }
      }

      return false;
    } catch (e) {
      print('BackendApi.verifyAdmin error: $e');
      return false;
    }
  }

  void dispose() {
    // _client.close(); // Do not close client as it is a singleton
  }
}

/// Employee with biometric data (face + fingerprint)
class EmployeeEmbedding {
  final String id;
  final String employeeId;
  final String employeeName;
  final String? department;
  final List<double> embedding;
  final String? fingerprintTemplate;
  final String? pin;
  final DateTime? enrolledAt;
  final bool isActive;

  EmployeeEmbedding({
    required this.id,
    required this.employeeId,
    required this.employeeName,
    this.department,
    required this.embedding,
    this.fingerprintTemplate,
    this.pin,
    this.enrolledAt,
    this.isActive = true,
  });

  factory EmployeeEmbedding.fromJson(Map<String, dynamic> json) {
    // Parse embedding from comma-separated string
    final embeddingStr = json['embedding'] as String? ?? '';
    final embedding = embeddingStr.isNotEmpty
        ? embeddingStr
              .split(',')
              .map((e) => double.tryParse(e.trim()) ?? 0.0)
              .toList()
        : <double>[];

    // Parse fingerprint template (Base64 String)
    final fingerprintTemplate = json['fingerprint_template'] as String?;

    // Debug: Verify embedding was loaded correctly
    print('');
    print('📦 Loading embedding for: ${json['employee_name']}');
    print('   Embedding string length: ${embeddingStr.length} chars');
    print('   Parsed embedding length: ${embedding.length} values');
    if (embedding.isNotEmpty) {
      final nonZeroCount = embedding.where((e) => e != 0.0).length;
      print('   Non-zero values: $nonZeroCount / ${embedding.length}');
      print(
        '   First 5 values: ${embedding.take(5).map((e) => e.toStringAsFixed(4)).join(', ')}',
      );
    }
    if (fingerprintTemplate != null) {
      print('   Fingerprint template length: ${fingerprintTemplate.length}');
    }
    print('');

    return EmployeeEmbedding(
      id: json['id']?.toString() ?? '',
      employeeId: json['employee_id'] ?? '',
      employeeName: json['employee_name'] ?? '',
      department: json['department'],
      embedding: embedding,
      fingerprintTemplate: fingerprintTemplate,
      pin: json['pin']?.toString(),
      enrolledAt: json['enrolled_at'] != null
          ? DateTime.tryParse(json['enrolled_at'])
          : null,
      isActive: json['is_active'] ?? true,
    );
  }
}

/// Employee for enrollment status
class EmployeeForEnrollment {
  final String employeeId;
  final String employeeName;
  final String? department;
  final bool hasFaceEnrolled;
  final bool hasFingerprintEnrolled;
  final bool hasPinEnrolled;

  EmployeeForEnrollment({
    required this.employeeId,
    required this.employeeName,
    this.department,
    this.hasFaceEnrolled = false,
    this.hasFingerprintEnrolled = false,
    this.hasPinEnrolled = false,
  });

  /// Helper to check if ANY biometric is enrolled
  bool get isEnrolled =>
      hasFaceEnrolled || hasFingerprintEnrolled || hasPinEnrolled;

  /// Helper to check if fully enrolled (both)
  bool get isFullyEnrolled => hasFaceEnrolled && hasFingerprintEnrolled;

  factory EmployeeForEnrollment.fromJson(Map<String, dynamic> json) {
    return EmployeeForEnrollment(
      employeeId: json['employee_id'] ?? '',
      employeeName: json['employee_name'] ?? '',
      department: json['department'],
      // Backend returns has_face_enrolled and has_fingerprint_enrolled now
      // Fallback to 'is_enrolled'/is_active check if fields missing (backward compat)
      hasFaceEnrolled: json['has_face_enrolled'] == true,
      hasFingerprintEnrolled: json['has_fingerprint_enrolled'] == true,
      hasPinEnrolled: json['has_pin_enrolled'] == true,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EmployeeForEnrollment && other.employeeId == employeeId;
  }

  @override
  int get hashCode => employeeId.hashCode;
}

/// Result of a punch operation
class PunchResult {
  final bool success;
  final String message;
  final String punchType;
  final String? attendanceId;
  final String? sessionDuration;

  PunchResult({
    required this.success,
    required this.message,
    required this.punchType,
    this.attendanceId,
    this.sessionDuration,
  });
}

/// Attendance record with punch in/out times
class AttendanceRecord {
  final String id;
  final String employeeId;
  final String? employeeName;
  final String workDate;
  final String? clockOnTime;
  final String? clockOffTime;
  final String? sessionDuration;
  final String? status;

  AttendanceRecord({
    required this.id,
    required this.employeeId,
    this.employeeName,
    required this.workDate,
    this.clockOnTime,
    this.clockOffTime,
    this.sessionDuration,
    this.status,
  });

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) {
    return AttendanceRecord(
      id: json['id']?.toString() ?? '',
      employeeId: json['employee_id'] ?? '',
      employeeName: json['employee_name'],
      workDate: json['work_date'] ?? '',
      clockOnTime: json['clock_on_for_the_day'],
      clockOffTime: json['clock_off_for_the_day'],
      sessionDuration: json['session_duration'],
      status: json['status'],
    );
  }

  bool get hasPunchedIn => clockOnTime != null && clockOnTime!.isNotEmpty;
  bool get hasPunchedOut => clockOffTime != null && clockOffTime!.isNotEmpty;
  bool get isActive => hasPunchedIn && !hasPunchedOut;
}
