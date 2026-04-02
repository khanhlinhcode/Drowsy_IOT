import 'dart:ui';

import 'package:flutter/material.dart';

class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
    this.borderRadius = 28,
    this.blurSigma = 18,
    this.width,
    this.height,
    this.gradientColors,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final double blurSigma;
  final double? width;
  final double? height;
  final List<Color>? gradientColors;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          width: width,
          height: height,
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(borderRadius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors:
                  gradientColors ??
                  <Color>[
                    Colors.white.withValues(alpha: 0.24),
                    Colors.white.withValues(alpha: 0.12),
                  ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.28),
              width: 1.2,
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 28,
                spreadRadius: 2,
                offset: const Offset(0, 14),
              ),
              BoxShadow(
                color: Colors.white.withValues(alpha: 0.08),
                blurRadius: 12,
                spreadRadius: -4,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}
