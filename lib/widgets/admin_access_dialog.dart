import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../api/backend_api.dart';

class AdminAccessDialog extends StatefulWidget {
  const AdminAccessDialog({super.key});

  @override
  State<AdminAccessDialog> createState() => _AdminAccessDialogState();
}

class _AdminAccessDialogState extends State<AdminAccessDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final BackendApi _backendApi = BackendApi();

  // Pattern Lock State
  final List<int> _pattern = [];
  final List<int> _correctPattern = [0, 3, 6, 7, 8]; // L shape
  Offset? _currentDragPosition;
  bool _isPatternError = false;

  // Password Login State
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  bool _isLoading = false;
  String? _errorMessage;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    // _backendApi.dispose(); // Removed: BackendApi is a singleton
    super.dispose();
  }

  // --- Pattern Lock Logic ---

  void _onPanStart(DragStartDetails details) {
    _pattern.clear();
    _isPatternError = false;
    _updatePattern(details.localPosition);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    _updatePattern(details.localPosition);
    setState(() {
      _currentDragPosition = details.localPosition;
    });
  }

  void _onPanEnd(DragEndDetails details) {
    _currentDragPosition = null;
    _validatePattern();
  }

  void _updatePattern(Offset localPosition) {
    // Grid dimensions
    final size = 280.0;
    final cellWidth = size / 3;

    // Check if within bounds
    if (localPosition.dx < 0 ||
        localPosition.dx > size ||
        localPosition.dy < 0 ||
        localPosition.dy > size) {
      return;
    }

    // Logic to detect which dot is closest
    final col = (localPosition.dx / cellWidth).floor();
    final row = (localPosition.dy / cellWidth).floor();

    // Safety clamp (although bounds check handles most)
    if (col < 0 || col > 2 || row < 0 || row > 2) return;

    final index = row * 3 + col;

    // Center of the target cell
    final center = Offset(
      col * cellWidth + cellWidth / 2,
      row * cellWidth + cellWidth / 2,
    );

    // Euclidean distance check (hit radius ~40% of cell width)
    final distance = (localPosition - center).distance;
    final hitRadius = cellWidth * 0.4;

    if (distance > hitRadius) return;

    if (!_pattern.contains(index)) {
      // Check for intermediate dots (Fill in gaps)
      if (_pattern.isNotEmpty) {
        final last = _pattern.last;
        final lastRow = last ~/ 3;
        final lastCol = last % 3;

        final diffRow = (row - lastRow).abs();
        final diffCol = (col - lastCol).abs();

        // If jumping over a dot (horizontal, vertical, or diagonal)
        if (diffRow % 2 == 0 && diffCol % 2 == 0) {
          // e.g., 0->2, 0->8
          final midRow = (lastRow + row) ~/ 2;
          final midCol = (lastCol + col) ~/ 2;
          final midIndex = midRow * 3 + midCol;

          if (!_pattern.contains(midIndex)) {
            setState(() {
              _pattern.add(midIndex);
            });
          }
        }
      }

      // Add actual dot
      setState(() {
        _pattern.add(index);
      });

      // Haptic feedback could be added here
    }
  }

  void _validatePattern() {
    if (_pattern.length != _correctPattern.length) {
      _showPatternError();
      return;
    }

    for (int i = 0; i < _pattern.length; i++) {
      if (_pattern[i] != _correctPattern[i]) {
        _showPatternError();
        return;
      }
    }

    // Success
    Navigator.pop(context, true);
  }

  void _showPatternError() {
    setState(() {
      _isPatternError = true;
    });
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _pattern.clear();
          _isPatternError = false;
        });
      }
    });
  }

  // --- Password Login Logic ---

  Future<void> _attemptLogin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = 'Please fill in all fields');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final success = await _backendApi.verifyAdmin(email, password);
      if (success && mounted) {
        Navigator.pop(context, true);
      } else {
        setState(() => _errorMessage = 'Invalid credentials');
      }
    } catch (e) {
      setState(() => _errorMessage = 'Error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            width: 400,
            constraints: const BoxConstraints(maxHeight: 520),
            decoration: BoxDecoration(
              color: Colors.grey.shade900.withOpacity(0.9),
              border: Border.all(
                color: Colors.white.withOpacity(0.1),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.5),
                  blurRadius: 30,
                  spreadRadius: 10,
                ),
              ],
            ),
            child: Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    physics:
                        const NeverScrollableScrollPhysics(), // Prevent swipe for pattern safety
                    children: [_buildPatternView(), _buildPasswordView()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        border: Border(
          bottom: BorderSide(color: Colors.white.withOpacity(0.05), width: 1),
        ),
      ),
      child: Theme(
        data: ThemeData(
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
        ),
        child: TabBar(
          controller: _tabController,
          indicatorSize: TabBarIndicatorSize.tab,
          indicator: BoxDecoration(
            color: Colors.blue.withOpacity(0.2),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.blue.withOpacity(0.5)),
          ),
          labelColor: Colors.blue.shade200,
          unselectedLabelColor: Colors.grey.shade400,
          labelStyle: GoogleFonts.poppins(
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
          unselectedLabelStyle: GoogleFonts.poppins(
            fontWeight: FontWeight.w500,
            fontSize: 14,
          ),
          dividerColor: Colors.transparent,
          tabs: const [
            Tab(
              text: 'Pattern Lock',
              icon: Icon(Icons.gesture_rounded, size: 20),
              iconMargin: EdgeInsets.only(bottom: 4),
            ),
            Tab(
              text: 'Password',
              icon: Icon(Icons.password_rounded, size: 20),
              iconMargin: EdgeInsets.only(bottom: 4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPatternView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Draw Admin Pattern',
          style: GoogleFonts.poppins(
            color: Colors.white.withOpacity(0.9),
            fontSize: 18,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Connect the dots to unlock',
          style: GoogleFonts.poppins(
            color: Colors.white.withOpacity(0.5),
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 32),
        Center(
          child: GestureDetector(
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: _onPanEnd,
            child: Container(
              width: 280,
              height: 280,
              color: Colors.transparent, // Capture touches
              child: CustomPaint(
                painter: PatternPainter(
                  pattern: _pattern,
                  currentPos: _currentDragPosition,
                  isError: _isPatternError,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPasswordView() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Admin Login',
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Enter your credentials to continue',
            style: GoogleFonts.poppins(color: Colors.white54, fontSize: 14),
          ),
          const SizedBox(height: 32),
          _buildTextField(
            controller: _emailController,
            focusNode: _emailFocusNode,
            label: 'Email Address',
            icon: Icons.alternate_email_rounded,
          ),
          const SizedBox(height: 16),
          _buildTextField(
            controller: _passwordController,
            focusNode: _passwordFocusNode,
            label: 'Password',
            icon: Icons.lock_outline_rounded,
            isPassword: true,
            isObscured: _obscurePassword,
            onToggleObscure: () =>
                setState(() => _obscurePassword = !_obscurePassword),
          ),
          const SizedBox(height: 24),
          if (_errorMessage != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: GoogleFonts.poppins(
                        color: Colors.red,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          const Spacer(),

          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _attemptLogin,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade700,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                disabledBackgroundColor: Colors.blue.shade900.withOpacity(0.5),
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      'Login',
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    required IconData icon,
    bool isPassword = false,
    bool isObscured = false,
    VoidCallback? onToggleObscure,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: focusNode.hasFocus
              ? Colors.blue.withOpacity(0.5)
              : Colors.white.withOpacity(0.1),
        ),
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        obscureText: isPassword ? isObscured : false,
        style: GoogleFonts.poppins(color: Colors.white),
        onTapOutside: (_) => focusNode.unfocus(),
        onTap: () => setState(() {}), // Refresh to update border color
        decoration: InputDecoration(
          labelText: label,
          labelStyle: GoogleFonts.poppins(
            color: focusNode.hasFocus ? Colors.blue.shade200 : Colors.white54,
          ),
          prefixIcon: Icon(
            icon,
            color: focusNode.hasFocus ? Colors.blue.shade200 : Colors.white38,
            size: 20,
          ),
          suffixIcon: isPassword
              ? IconButton(
                  icon: Icon(
                    isObscured
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    color: Colors.white38,
                    size: 20,
                  ),
                  onPressed: onToggleObscure,
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          floatingLabelBehavior: FloatingLabelBehavior.auto,
        ),
      ),
    );
  }
}

class PatternPainter extends CustomPainter {
  final List<int> pattern;
  final Offset? currentPos;
  final bool isError;

  PatternPainter({
    required this.pattern,
    this.currentPos,
    this.isError = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cellWidth = size.width / 3;
    final dotRadius = 6.0;

    final dotPaint = Paint()
      ..color = Colors.white.withOpacity(0.1)
      ..style = PaintingStyle.fill;

    final activeDotPaint = Paint()
      ..color = isError ? Colors.redAccent : Colors.blueAccent
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: isError
            ? [Colors.redAccent, Colors.red]
            : [Colors.cyanAccent, Colors.blueAccent],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final linePaint = Paint()
      ..color = isError ? Colors.redAccent : Colors.blueAccent
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Create a glowing effect for the line
    final glowPaint = Paint()
      ..color = (isError ? Colors.red : Colors.blue).withOpacity(0.4)
      ..strokeWidth = 12.0
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    // Draw grid dots
    final centers = <Offset>[];
    for (int r = 0; r < 3; r++) {
      for (int c = 0; c < 3; c++) {
        final center = Offset(
          c * cellWidth + cellWidth / 2,
          r * cellWidth + cellWidth / 2,
        );
        centers.add(center);

        // Draw dot background
        canvas.drawCircle(center, dotRadius, dotPaint);

        if (pattern.contains(r * 3 + c)) {
          // Draw selection glow
          canvas.drawCircle(
            center,
            24,
            Paint()
              ..color = (isError ? Colors.red : Colors.blue).withOpacity(0.15)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
          );

          // Draw active dot ring
          canvas.drawCircle(
            center,
            12,
            Paint()
              ..color = (isError ? Colors.red : Colors.blue).withOpacity(0.2)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5,
          );

          // Draw active dot center
          canvas.drawCircle(center, dotRadius + 1, activeDotPaint);
        }
      }
    }

    // Draw lines
    final path = Path();
    if (pattern.isNotEmpty) {
      path.moveTo(centers[pattern.first].dx, centers[pattern.first].dy);
      for (int i = 1; i < pattern.length; i++) {
        path.lineTo(centers[pattern[i]].dx, centers[pattern[i]].dy);
      }

      if (currentPos != null) {
        path.lineTo(currentPos!.dx, currentPos!.dy);
      }

      // Draw glow then line
      canvas.drawPath(path, glowPaint);
      canvas.drawPath(path, linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant PatternPainter oldDelegate) {
    return true;
  }
}
