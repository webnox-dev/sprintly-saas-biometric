import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/backend_api.dart';
import 'kiosk_screen.dart';
import 'kiosk_pairing_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);

    _controller.forward();

    _checkPairingAndNavigate();
  }

  Future<void> _checkPairingAndNavigate() async {
    final prefs = await SharedPreferences.getInstance();
    final orgId = prefs.getString('kiosk_organization_id');
    final apiUrl = prefs.getString('kiosk_api_url');

    if (apiUrl != null && apiUrl.isNotEmpty) {
      BackendApi.setBaseUrl(apiUrl);
    }
    if (orgId != null && orgId.isNotEmpty) {
      await BackendApi().setOrganizationId(orgId);
    }

    // Wait for minimum splash duration (1.5 seconds)
    await Future.delayed(const Duration(milliseconds: 1500));

    if (!mounted) return;

    if (orgId != null && orgId.isNotEmpty) {
      // Organization already paired -> Go straight to Face Kiosk Attendance
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const KioskScreen()),
      );
    } else {
      // Fresh install or unpaired -> Go to QR Pairing Screen
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const KioskPairingScreen()),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: FadeTransition(
          opacity: _animation,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/images/image.png',
                width: 200,
                height: 200,
                errorBuilder: (context, error, stackTrace) {
                  return const Icon(
                    Icons.security_rounded,
                    color: Colors.white,
                    size: 80,
                  );
                },
              ),
              const SizedBox(height: 32),
              Text(
                'WEBNOX SPRINTLY',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'BIOMETRIC ATTENDANCE',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
