import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';
import '../../services/backend_attendance_service.dart';
import '../../services/fingerprint_service.dart';
import '../../services/face_embedding_service.dart';
import '../../api/backend_api.dart';
import 'enrollment_screen.dart';

class ManageEmployeesScreen extends StatefulWidget {
  const ManageEmployeesScreen({super.key});

  @override
  State<ManageEmployeesScreen> createState() => _ManageEmployeesScreenState();
}

class _ManageEmployeesScreenState extends State<ManageEmployeesScreen> {
  late BackendApi _backendApi;
  late BackendAttendanceService _attendanceService;
  late FingerprintService _fingerprintService;
  late FaceEmbeddingService _faceEmbeddingService;

  List<EmployeeEmbedding> _employees = [];
  List<EmployeeEmbedding> _filteredEmployees = [];
  final TextEditingController _searchController = TextEditingController();
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
    await _loadEmployees();
  }

  Future<void> _loadEmployees() async {
    setState(() => _isLoading = true);
    try {
      final employees = await _attendanceService.getEnrolledEmployees();
      setState(() {
        _employees = employees;
        _isLoading = false;
        _filterEmployees(_searchController.text);
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error loading employees: $e')));
      }
    }
  }

  void _filterEmployees(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredEmployees = _employees;
      } else {
        _filteredEmployees = _employees
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

  Future<void> _navigateToEnrollment() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const EnrollmentScreen()),
    );

    // Refresh the list when returning from enrollment screen
    if (mounted && result == true) {
      await _loadEmployees();
    } else if (mounted) {
      // Also refresh even if no explicit result, in case enrollment happened
      await _loadEmployees();
    }
  }

  Future<void> _deleteEmployee(EmployeeEmbedding employee) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Delete Enrollment?',
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'Are you sure you want to delete biometric data for "${employee.employeeName}" (${employee.employeeId})?\n\nThis will remove their fingerprint data but NOT their employee record.',
          style: GoogleFonts.poppins(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: GoogleFonts.poppins(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade900,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Text(
              'Delete',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final success = await _attendanceService.deleteEnrollment(
          employee.employeeId,
        );
        if (mounted) {
          if (success) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '✅ Deleted enrollment for ${employee.employeeName}',
                  style: GoogleFonts.poppins(),
                ),
                backgroundColor: Colors.green,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            );
            await _loadEmployees(); // Refresh list
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '❌ Failed to delete enrollment',
                  style: GoogleFonts.poppins(),
                ),
                backgroundColor: Colors.red,
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '❌ Error deleting: $e',
                style: GoogleFonts.poppins(),
              ),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _attendanceService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade900,
      appBar: AppBar(
        title: Text(
          'Enrolled Employees',
          style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Search Filter View
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
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
                  hintText: 'Search staff name or ID...',
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

          // List Header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Row(
              children: [
                Text(
                  _searchController.text.isEmpty
                      ? 'All Records'
                      : 'Search Results',
                  style: GoogleFonts.poppins(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_filteredEmployees.length} registered',
                  style: GoogleFonts.poppins(
                    color: Colors.white30,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadEmployees,
              color: Colors.blueAccent,
              backgroundColor: const Color(0xFF1E1E26),
              child: _isLoading
                  ? _buildSkeletonList()
                  : _filteredEmployees.isEmpty
                  ? SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: Container(
                        height: MediaQuery.of(context).size.height * 0.5,
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.people_alt_rounded,
                              size: 80,
                              color: Colors.white12,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No staff found',
                              style: GoogleFonts.poppins(
                                color: Colors.white38,
                                fontSize: 18,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _filteredEmployees.length,
                      itemBuilder: (context, index) {
                        final employee = _filteredEmployees[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.05),
                            ),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            leading: Hero(
                              tag: 'avatar_${employee.employeeId}',
                              child: CircleAvatar(
                                radius: 24,
                                backgroundColor: Colors.blue.shade900,
                                child: Text(
                                  employee.employeeName.isNotEmpty
                                      ? employee.employeeName[0].toUpperCase()
                                      : '?',
                                  style: GoogleFonts.poppins(
                                    color: Colors.blue.shade100,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                ),
                              ),
                            ),
                            title: Text(
                              employee.employeeName,
                              style: GoogleFonts.poppins(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 4),
                                Text(
                                  employee.employeeId,
                                  style: GoogleFonts.poppins(
                                    color: Colors.white54,
                                    fontSize: 13,
                                  ),
                                  maxLines: 1,
                                ),
                                if (employee.department != null &&
                                    employee.department!.isNotEmpty)
                                  Text(
                                    employee.department!,
                                    style: GoogleFonts.poppins(
                                      color: Colors.white38,
                                      fontSize: 12,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(
                                    Icons.fingerprint_rounded,
                                    color: Colors.blue.shade300,
                                  ),
                                  onPressed: () =>
                                      _navigateToReEnrollment(employee),
                                  tooltip: 'Update Fingerprint',
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.delete_outline_rounded,
                                    color: Colors.red.shade300,
                                  ),
                                  onPressed: () => _deleteEmployee(employee),
                                  tooltip: 'Delete Enrollment',
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _navigateToEnrollment,
        backgroundColor: Colors.blue.shade600,
        foregroundColor: Colors.white,
        elevation: 4,
        child: const Icon(Icons.add_rounded, size: 28),
      ),
    );
  }

  Future<void> _navigateToReEnrollment(EmployeeEmbedding employee) async {
    // Map EmployeeEmbedding to EmployeeForEnrollment
    final empForEnroll = EmployeeForEnrollment(
      employeeId: employee.employeeId,
      employeeName: employee.employeeName,
      department: employee.department,
      hasFaceEnrolled: employee.embedding.isNotEmpty,
      hasFingerprintEnrolled: employee.fingerprintTemplate != null,
    );

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => EnrollmentScreen(initialEmployee: empForEnroll),
      ),
    );

    if (mounted && result == true) {
      await _loadEmployees();
    }
  }

  Widget _buildSkeletonList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: 6,
      itemBuilder: (context, index) {
        return Shimmer.fromColors(
          baseColor: Colors.white.withOpacity(0.05),
          highlightColor: Colors.white.withOpacity(0.1),
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            height: 80,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        );
      },
    );
  }
}
