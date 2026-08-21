import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:ui';
import 'enrollment_screen.dart';
import 'manage_employees_screen.dart';
import 'reports_screen.dart';
import '../fingerprint_test_screen.dart';
import '../kiosk_pairing_screen.dart';

class AdminDashboard extends StatelessWidget {
  const AdminDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    // Get screen width for responsive layout
    // final screenWidth = MediaQuery.of(context).size.width;
    // final crossAxisCount = screenWidth > 600 ? 3 : 1;

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F12),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          'ADMIN CONTROL PANEL',
          style: GoogleFonts.poppins(
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
            fontSize: 18,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: Stack(
        children: [
          // Background Glows for Premium Look
          Positioned(
            top: -100,
            left: -100,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blue.withOpacity(0.08),
              ),
            ),
          ),
          Positioned(
            bottom: -150,
            right: -100,
            child: Container(
              width: 500,
              height: 500,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.purple.withOpacity(0.05),
              ),
            ),
          ),

          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24.0,
                    vertical: 20.0,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 40,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildWelcomeHeader(),
                        const SizedBox(height: 40),

                        Text(
                          'SYSTEM MANAGEMENT',
                          style: GoogleFonts.poppins(
                            color: Colors.white38,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 20),

                        // Responsive Grid with Auto-Calculated Aspect Ratio
                        // For 4 items:
                        // - Mobile (<600): 1 col (list)
                        // - Tablet (600-1100): 2 cols (2x2 grid, balanced)
                        // - Desktop (>1100): 4 cols (1 row)
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final width = constraints.maxWidth;
                            int cols;
                            double ratio;

                            if (width > 1100) {
                              cols = 4;
                              ratio = 1.0;
                            } else if (width > 600) {
                              cols = 2;
                              ratio = 1.6; // Wider cards for landscape tablet
                            } else {
                              cols = 1;
                              ratio = 2.8;
                            }

                            return GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: cols,
                                    crossAxisSpacing: 20,
                                    mainAxisSpacing: 20,
                                    childAspectRatio: ratio,
                                  ),
                              itemCount: 5,
                              itemBuilder: (context, index) {
                                if (index == 0) {
                                  return _buildMenuCard(
                                    context,
                                    title: 'Attendance Reports',
                                    icon: Icons.assessment_rounded,
                                    color: Colors.blue,
                                    onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => const ReportsScreen(),
                                      ),
                                    ),
                                    description: 'Review & export logs',
                                  );
                                } else if (index == 1) {
                                  return _buildMenuCard(
                                    context,
                                    title: 'Manage Employees',
                                    icon: Icons.people_alt_rounded,
                                    color: Colors.purple,
                                    onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const ManageEmployeesScreen(),
                                      ),
                                    ),
                                    description: 'Update or remove data',
                                  );
                                } else if (index == 2) {
                                  return _buildMenuCard(
                                    context,
                                    title: 'New Enrollment',
                                    icon: Icons.person_add_alt_1_rounded,
                                    color: Colors.green,
                                    onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const EnrollmentScreen(),
                                      ),
                                    ),
                                    description: 'Register fingerprints',
                                  );
                                } else if (index == 3) {
                                  return _buildMenuCard(
                                    context,
                                    title: 'Device Diagnostics',
                                    icon: Icons.fingerprint_rounded,
                                    color: Colors.orange,
                                    onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const FingerprintTestScreen(),
                                      ),
                                    ),
                                    description: 'Test fingerprint scanner',
                                  );
                                } else {
                                  return _buildMenuCard(
                                    context,
                                    title: 'Re-Pair Organization',
                                    icon: Icons.qr_code_scanner_rounded,
                                    color: Colors.teal,
                                    onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const KioskPairingScreen(),
                                      ),
                                    ),
                                    description: 'Scan new Admin QR code',
                                  );
                                }
                              },
                            );
                          },
                        ),

                        const SizedBox(height: 48),
                        _buildFooterInfo(),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWelcomeHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hello, Administrator',
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Manage your system settings and data below.',
          style: GoogleFonts.poppins(color: Colors.white54, fontSize: 14),
        ),
      ],
    );
  }

  Widget _buildMenuCard(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    required String description,
  }) {
    // Check if we are in list mode (mobile/vertical) or grid mode
    final isListMode = MediaQuery.of(context).size.width <= 600;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [color.withOpacity(0.12), Colors.transparent],
              ),
            ),
            child: isListMode
                ? Row(
                    children: [
                      _buildIconBox(icon, color),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: GoogleFonts.poppins(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              description,
                              style: GoogleFonts.poppins(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.white24,
                        size: 20,
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildIconBox(icon, color),
                      const Spacer(),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          title,
                          style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            height: 1.1,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: GoogleFonts.poppins(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildIconBox(IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.1),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Icon(icon, color: color, size: 30),
    );
  }

  Widget _buildFooterInfo() {
    return Center(
      child: Column(
        children: [
          Icon(Icons.verified_user_outlined, color: Colors.white10, size: 24),
          const SizedBox(height: 12),
          Text(
            'WEBNOX SPRINTLY BIOMETRIC v1.0.2',
            style: GoogleFonts.poppins(
              color: Colors.white12,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
  }
}
