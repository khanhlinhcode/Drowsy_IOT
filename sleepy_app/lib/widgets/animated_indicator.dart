import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/sleep_model.dart';

class AnimatedIndicator extends StatefulWidget {
  const AnimatedIndicator({super.key, required this.state, this.size = 140});

  final SleepState state;
  final double size;

  @override
  State<AnimatedIndicator> createState() => _AnimatedIndicatorState();
}

class _AnimatedIndicatorState extends State<AnimatedIndicator>
    with TickerProviderStateMixin {
  late final AnimationController _breathingController;
  late final AnimationController _alertController;
  late final AnimationController _orbitController;

  @override
  void initState() {
    super.initState();
    _breathingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..repeat(reverse: true);

    _alertController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _orbitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 6000),
    )..repeat();

    _syncAlertAnimation();
  }

  @override
  void didUpdateWidget(covariant AnimatedIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _syncAlertAnimation();
    }
  }

  void _syncAlertAnimation() {
    switch (widget.state) {
      case SleepState.sleep:
        _alertController
          ..duration = const Duration(milliseconds: 860)
          ..repeat(reverse: true);
        _orbitController.duration = const Duration(milliseconds: 2000);
        break;
      case SleepState.sleepy:
        _alertController
          ..duration = const Duration(milliseconds: 1500)
          ..repeat(reverse: true);
        _orbitController.duration = const Duration(milliseconds: 4000);
        break;
      case SleepState.normal:
        _alertController
          ..stop()
          ..value = 0;
        _orbitController.duration = const Duration(milliseconds: 6000);
        break;
    }
  }

  @override
  void dispose() {
    _breathingController.dispose();
    _alertController.dispose();
    _orbitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(widget.state);

    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        _breathingController,
        _alertController,
        _orbitController,
      ]),
      builder: (context, child) {
        final breathing = _breathingController.value;
        final alert = _alertController.value;
        final orbit = _orbitController.value;

        final pulseBoost = switch (widget.state) {
          SleepState.sleep => 0.08 * alert,
          SleepState.sleepy => 0.04 * alert,
          SleepState.normal => 0.0,
        };

        final scale = 1 + (breathing * 0.025) + pulseBoost;
        final glow = switch (widget.state) {
          SleepState.sleep => 36 + (alert * 10),
          SleepState.sleepy => 28 + (alert * 6),
          SleepState.normal => 22 + (breathing * 5),
        };

        final spread = switch (widget.state) {
          SleepState.sleep => 5 + (alert * 3),
          SleepState.sleepy => 3 + (alert * 2),
          SleepState.normal => 2 + (breathing * 1.2),
        };

        return Transform.scale(
          scale: scale,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                // Outer glow
                Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: color.withValues(alpha: 0.30),
                        blurRadius: glow,
                        spreadRadius: spread,
                      ),
                    ],
                  ),
                ),

                // ── Orbiting ring ──
                Transform.rotate(
                  angle: orbit * 2 * math.pi,
                  child: CustomPaint(
                    size: Size(widget.size * 0.88, widget.size * 0.88),
                    painter: _OrbitRingPainter(
                      color: color,
                      progress: orbit,
                      strokeWidth: 1.5,
                    ),
                  ),
                ),

                // ── Second orbit ring (opposite direction) ──
                Transform.rotate(
                  angle: -orbit * 2 * math.pi * 0.7,
                  child: CustomPaint(
                    size: Size(widget.size * 0.78, widget.size * 0.78),
                    painter: _OrbitRingPainter(
                      color: color.withValues(alpha: 0.30),
                      progress: 1 - orbit,
                      strokeWidth: 1.0,
                    ),
                  ),
                ),

                // Main sphere — gradient with glass edge
                Container(
                  width: widget.size * 0.62,
                  height: widget.size * 0.62,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-0.3, -0.35),
                      radius: 0.85,
                      colors: <Color>[
                        Colors.white.withValues(alpha: 0.90),
                        color.withValues(alpha: 0.80),
                        color.withValues(alpha: 0.50),
                      ],
                      stops: const <double>[0.0, 0.45, 1.0],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.55),
                      width: 1.2,
                    ),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.22),
                        blurRadius: 14,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                ),

                // ── State icon inside sphere ──
                _StateIcon(state: widget.state, size: widget.size * 0.24),

                // Inner highlight
                Positioned(
                  top: widget.size * 0.22,
                  left: widget.size * 0.26,
                  child: Container(
                    width: widget.size * 0.18,
                    height: widget.size * 0.10,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(100),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: <Color>[
                          Colors.white.withValues(alpha: 0.50),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),

                // ── Orbiting dots ──
                ..._buildOrbitDots(orbit, color),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildOrbitDots(double orbit, Color color) {
    final dots = <Widget>[];
    const dotCount = 3;
    final radius = widget.size * 0.44;

    for (int i = 0; i < dotCount; i++) {
      final angle = (orbit * 2 * math.pi) + (i * 2 * math.pi / dotCount);
      final dx = math.cos(angle) * radius;
      final dy = math.sin(angle) * radius;
      final dotSize = 3.0 + (i * 1.0);

      dots.add(
        Positioned(
          left: widget.size / 2 + dx - dotSize / 2,
          top: widget.size / 2 + dy - dotSize / 2,
          child: Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.7 - (i * 0.15)),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: color.withValues(alpha: 0.5),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return dots;
  }

  Color _statusColor(SleepState state) {
    switch (state) {
      case SleepState.normal:
        return const Color(0xFF34D399);
      case SleepState.sleepy:
        return const Color(0xFFFBBF24);
      case SleepState.sleep:
        return const Color(0xFFF87171);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// State Icon — icon inside the sphere
// ─────────────────────────────────────────────────────────────────────────────
class _StateIcon extends StatelessWidget {
  const _StateIcon({required this.state, required this.size});

  final SleepState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final iconData = switch (state) {
      SleepState.normal => Icons.visibility_rounded,
      SleepState.sleepy => Icons.nights_stay_rounded,
      SleepState.sleep => Icons.warning_amber_rounded,
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 380),
      transitionBuilder: (child, animation) {
        return ScaleTransition(scale: animation, child: child);
      },
      child: Icon(
        iconData,
        key: ValueKey<SleepState>(state),
        size: size,
        color: Colors.white.withValues(alpha: 0.85),
        shadows: <Shadow>[
          Shadow(
            color: Colors.black.withValues(alpha: 0.30),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Orbit Ring Painter — dashed arc ring
// ─────────────────────────────────────────────────────────────────────────────
class _OrbitRingPainter extends CustomPainter {
  _OrbitRingPainter({
    required this.color,
    required this.progress,
    this.strokeWidth = 1.5,
  });

  final Color color;
  final double progress;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.40)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Draw arc segments (dashed effect)
    const segments = 8;
    const gapAngle = math.pi / 20;
    const segmentAngle = (2 * math.pi / segments) - gapAngle;

    for (int i = 0; i < segments; i++) {
      final startAngle = (i * 2 * math.pi / segments) + gapAngle / 2;
      // Fade opacity based on segment position
      final opacity = 0.2 + 0.6 * ((i + progress * segments) % segments / segments);
      paint.color = color.withValues(alpha: opacity);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        segmentAngle,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OrbitRingPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
