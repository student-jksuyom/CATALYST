import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'home_screen.dart';

class LandingScreen extends StatefulWidget {
  const LandingScreen({super.key, this.homeBuilder});

  final WidgetBuilder? homeBuilder;

  @override
  State<LandingScreen> createState() => _LandingScreenState();
}

class _LandingScreenState extends State<LandingScreen> {
  Timer? _navigationTimer;
  var _didNavigate = false;

  static const _backgroundColor = Color(0xFFF2FEFF);
  static const _brandGradient = LinearGradient(
    colors: [Color(0xFF9564F6), Color(0xFF579AF5)],
  );

  @override
  void initState() {
    super.initState();
    _navigationTimer = Timer(const Duration(seconds: 4), _openHome);
  }

  @override
  void dispose() {
    _navigationTimer?.cancel();
    super.dispose();
  }

  void _openHome() {
    if (!mounted || _didNavigate) return;
    _didNavigate = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: widget.homeBuilder ?? (context) => const HomeScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(color: _backgroundColor),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final iconWidth = math.min(
                math.min(
                  constraints.maxWidth * 0.5,
                  constraints.maxHeight * 0.23,
                ),
                225.0,
              );

              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/images/catalyst_scales.png',
                      width: iconWidth,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 10),
                    _GradientText(
                      'CATALYST',
                      gradient: _brandGradient,
                      style: const TextStyle(
                        fontFamily: 'Fredoka',
                        fontSize: 58,
                        fontWeight: FontWeight.w600,
                        height: 1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    _GradientText(
                      'CASE-TO-LAW SYSTEM',
                      gradient: _brandGradient,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        height: 1,
                        letterSpacing: 2.5,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _GradientText extends StatelessWidget {
  const _GradientText(this.text, {required this.gradient, required this.style});

  final String text;
  final Gradient gradient;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => gradient.createShader(bounds),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 1,
        softWrap: false,
        style: style,
      ),
    );
  }
}
