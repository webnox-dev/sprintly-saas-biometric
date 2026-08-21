import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shimmer/shimmer.dart';
import '../../services/backend_attendance_service.dart';
import '../../services/fingerprint_service.dart';
import '../../services/face_embedding_service.dart';
import '../../api/backend_api.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late BackendApi _backendApi;
  late BackendAttendanceService _attendanceService;
  late FingerprintService _fingerprintService;
  late FaceEmbeddingService _faceEmbeddingService;

  List<EmployeeEmbedding> _enrolledEmployees = [];
  List<EmployeeEmbedding> _filteredEmployees = [];
  final TextEditingController _searchController = TextEditingController();
  Map<String, AttendanceRecord> _todayAttendance =
      {}; // employeeId -> attendance
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    _backendApi = BackendApi();
    _fingerprintService = FingerprintService();
    _faceEmbeddingService = FaceEmbeddingService();
    _attendanceService = BackendAttendanceService(
      _backendApi,
      _faceEmbeddingService,
      _fingerprintService,
    );
    await _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      // Load enrolled employees and today's attendance in parallel
      final employeesFuture = _attendanceService.getEnrolledEmployees();
      final attendanceFuture = _backendApi.getTodayAttendance();

      final results = await Future.wait([employeesFuture, attendanceFuture]);
      final employees = results[0] as List<EmployeeEmbedding>;
      var attendanceList = results[1] as List<AttendanceRecord>;

      print('📊 Reports: Loaded ${employees.length} employees');
      print(
        '📊 Reports: Loaded ${attendanceList.length} bulk attendance records',
      );

      // FALLBACK: If bulk attendance is empty, try individual fetch
      // This handles cases where /attendance/today might verify date differently on server
      if (attendanceList.isEmpty && employees.isNotEmpty) {
        print('⚠️ Bulk attendance empty. Trying fallback fetch by date...');
        final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

        final fallbackList = <AttendanceRecord>[];
        for (var emp in employees) {
          final empRecords = await _backendApi.getEmployeeAttendanceByDate(
            emp.employeeId,
            todayStr,
          );
          fallbackList.addAll(empRecords);
        }

        if (fallbackList.isNotEmpty) {
          print('✅ Fallback found ${fallbackList.length} records');
          attendanceList = fallbackList;
        } else {
          print('❌ Fallback also found no records for date: $todayStr');
        }
      }

      // Create a map of employeeId -> attendance record
      final attendanceMap = <String, AttendanceRecord>{};
      for (var attendance in attendanceList) {
        // Handle potential case sensitivity or padding mismatch
        attendanceMap[attendance.employeeId] = attendance;

        // Also try lowercase key just in case
        attendanceMap[attendance.employeeId.toLowerCase()] = attendance;
      }

      setState(() {
        _enrolledEmployees = employees;
        _todayAttendance = attendanceMap;
        _isLoading = false;
        _filterEmployees(_searchController.text);
      });
    } catch (e) {
      print('ReportsScreen _loadData error: $e');
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error loading data: $e',
              style: GoogleFonts.poppins(),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _filterEmployees(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredEmployees = _enrolledEmployees;
      } else {
        _filteredEmployees = _enrolledEmployees
            .where(
              (emp) =>
                  emp.employeeName.toLowerCase().contains(
                    query.toLowerCase(),
                  ) ||
                  emp.employeeId.toLowerCase().contains(query.toLowerCase()),
            )
            .toList();
      }
    });
  }

  String _formatTime(String? timeString) {
    if (timeString == null || timeString.isEmpty) return '--:--';
    try {
      // Parse ISO format time and format it
      final dateTime = DateTime.parse(timeString);
      return DateFormat('hh:mm a').format(dateTime);
    } catch (e) {
      return timeString;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _attendanceService.dispose();
    super.dispose();
  }

  Future<void> _exportReport() async {
    if (_enrolledEmployees.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No data to export')));
      return;
    }

    try {
      List<List<dynamic>> rows = [];

      // Header
      rows.add([
        "Employee ID",
        "Name",
        "Department",
        "Enrollment Status",
        "Punch IN Time",
        "Punch OUT Time",
        "Duration",
        "Status",
      ]);

      // Data
      for (var emp in _enrolledEmployees) {
        final attendance = _todayAttendance[emp.employeeId];
        rows.add([
          emp.employeeId,
          emp.employeeName,
          emp.department ?? "N/A",
          emp.isActive ? "Enrolled" : "Disabled",
          _formatTime(attendance?.clockOnTime),
          _formatTime(attendance?.clockOffTime),
          attendance?.sessionDuration ?? "--",
          attendance?.isActive == true
              ? "Present (IN)"
              : (attendance?.hasPunchedOut == true
                    ? "Present (OUT)"
                    : "Absent"),
        ]);
      }

      String csvData = const ListToCsvConverter().convert(rows);

      final directory = await getTemporaryDirectory();
      final path =
          "${directory.path}/Attendance_Report_${DateFormat('yyyyMMdd').format(DateTime.now())}.csv";
      final file = File(path);
      await file.writeAsString(csvData);

      await Share.shareXFiles(
        [XFile(path)],
        text:
            'Attendance Report - ${DateFormat('dd MMM yyyy').format(DateTime.now())}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F12),
      appBar: AppBar(
        title: Text(
          'Attendance Reports',
          style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 18),
          maxLines: 2,
          overflow: TextOverflow.visible,
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded),
            onPressed: _exportReport,
            tooltip: 'Export CSV',
            color: Colors.blue.shade200,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Summary section
          _buildSummarySection(),

          // Search Filter View
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              height: 50,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: TextField(
                controller: _searchController,
                onChanged: _filterEmployees,
                style: GoogleFonts.poppins(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search by name or ID...',
                  hintStyle: GoogleFonts.poppins(color: Colors.white24),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: Colors.white38,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 11),
                ),
              ),
            ),
          ),

          // Header for list
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            child: Row(
              children: [
                Text(
                  _searchController.text.isEmpty
                      ? 'All Employees'
                      : 'Search Results',
                  style: GoogleFonts.poppins(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_filteredEmployees.length} ${_filteredEmployees.length == 1 ? 'staff' : 'staffs'}',
                  style: GoogleFonts.poppins(
                    color: Colors.white30,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          // Employees list with Shimmer
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadData,
              color: Colors.blueAccent,
              backgroundColor: const Color(0xFF1E1E26),
              child: _isLoading
                  ? _buildSkeletonList()
                  : _filteredEmployees.isEmpty
                  ? SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: SizedBox(
                        height: MediaQuery.of(context).size.height * 0.4,
                        child: _buildEmptyState(),
                      ),
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _filteredEmployees.length,
                      itemBuilder: (context, index) {
                        final emp = _filteredEmployees[index];
                        return _buildEmployeeCard(emp);
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSkeletonList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: 5,
      itemBuilder: (context, index) {
        return Shimmer.fromColors(
          baseColor: Colors.white.withOpacity(0.05),
          highlightColor: Colors.white.withOpacity(0.1),
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            height: 90,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSummarySection() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildStatItem(
              icon: Icons.people_rounded,
              value: '${_enrolledEmployees.length}',
              label: 'Total Enrolled',
              color: Colors.blueAccent,
            ),
          ),
          _buildDivider(),
          Expanded(
            child: _buildStatItem(
              icon: Icons.check_circle_outline_rounded,
              value:
                  '${_todayAttendance.values.where((a) => a.hasPunchedIn).length}',
              label: 'Present Today',
              color: Colors.greenAccent,
            ),
          ),
          _buildDivider(),
          Expanded(
            child: _buildStatItem(
              icon: Icons.login_rounded,
              value:
                  '${_todayAttendance.values.where((a) => a.isActive).length}',
              label: 'Currently In',
              color: Colors.orangeAccent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Container(width: 1, height: 40, color: Colors.white10);
  }

  Widget _buildStatItem({
    required IconData icon,
    required String value,
    required String label,
    required Color color,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color.withOpacity(0.5), size: 18),
        const SizedBox(height: 8),
        Text(
          value,
          style: GoogleFonts.poppins(
            color: color,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          label,
          style: GoogleFonts.poppins(
            color: Colors.white38,
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildEmployeeCard(EmployeeEmbedding emp) {
    final attendance = _todayAttendance[emp.employeeId];
    final isPresent = attendance?.hasPunchedIn ?? false;
    final currentlyIn = attendance?.isActive ?? false;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Stack(
          alignment: Alignment.bottomRight,
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: Colors.blue.withOpacity(0.1),
              child: Text(
                emp.employeeName[0].toUpperCase(),
                style: GoogleFonts.poppins(
                  color: Colors.blue.shade200,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ),
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: isPresent ? Colors.green : Colors.grey.shade700,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF0F0F12), width: 2),
              ),
            ),
          ],
        ),
        title: Text(
          emp.employeeName,
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Row(
          children: [
            Flexible(
              child: Text(
                emp.employeeId,
                style: GoogleFonts.poppins(color: Colors.white38, fontSize: 13),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (emp.department != null) ...[
              const SizedBox(width: 8),
              Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(
                  color: Colors.white12,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  emp.department!,
                  style: GoogleFonts.poppins(
                    color: Colors.white38,
                    fontSize: 13,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
        trailing: currentlyIn
            ? Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'IN',
                  style: GoogleFonts.poppins(
                    color: Colors.blueAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              )
            : isPresent
            ? Icon(
                Icons.check_circle_outline_rounded,
                color: Colors.green.withOpacity(0.5),
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: _buildAttendanceDetails(attendance),
          ),
        ],
      ),
    );
  }

  Widget _buildAttendanceDetails(AttendanceRecord? attendance) {
    if (attendance == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Text(
            'No attendance records found for today.',
            style: GoogleFonts.poppins(color: Colors.white24, fontSize: 13),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          _buildPunchRow(
            'Clock In',
            attendance.clockOnTime,
            Icons.login_rounded,
            Colors.green,
          ),
          if (attendance.hasPunchedOut) ...[
            const SizedBox(height: 12),
            _buildPunchRow(
              'Clock Out',
              attendance.clockOffTime,
              Icons.logout_rounded,
              Colors.orange,
            ),
            const SizedBox(height: 12),
            _buildPunchRow(
              'Total Duration',
              attendance.sessionDuration,
              Icons.timer_outlined,
              Colors.blue,
            ),
          ] else if (attendance.hasPunchedIn) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.sync, color: Colors.blueAccent, size: 16),
                const SizedBox(width: 12),
                Text(
                  'Currently working...',
                  style: GoogleFonts.poppins(
                    color: Colors.blueAccent,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPunchRow(
    String label,
    String? time,
    IconData icon,
    Color color,
  ) {
    return Row(
      children: [
        Icon(icon, color: color.withOpacity(0.7), size: 16),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.poppins(color: Colors.white54, fontSize: 13),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          _formatTime(time),
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people_outline_rounded, color: Colors.white12, size: 80),
          const SizedBox(height: 24),
          Text(
            'No employees enrolled yet',
            style: GoogleFonts.poppins(color: Colors.white38, fontSize: 18),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
