import 'package:flutter/material.dart';

import '../models/sleep_model.dart';

class AnimatedIndicator extends StatefulWidget {
  const AnimatedIndicator({super.key, required this.state, this.size = 148});

  final SleepState state;
  final double size;

  @override
  State<AnimatedIndicator> createState() => _AnimatedIndicatorState();
}

class _AnimatedIndicatorState extends State<AnimatedIndicator>
    with TickerProviderStateMixin {
  late final AnimationController _breathingController;
  late final AnimationController _alertController;

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
        break;
      case SleepState.sleepy:
        _alertController
          ..duration = const Duration(milliseconds: 1500)
          ..repeat(reverse: true);
        break;
      case SleepState.normal:
        _alertController
          ..stop()
          ..value = 0;
        break;
    }
  }

  @override
  void dispose() {
    _breathingController.dispose();
    _alertController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(widget.state);

    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        _breathingController,
        _alertController,
      ]),
      builder: (context, child) {
        final breathing = _breathingController.value;
        final alert = _alertController.value;

        final pulseBoost = switch (widget.state) {
          SleepState.sleep => 0.10 * alert,
          SleepState.sleepy => 0.05 * alert,
          SleepState.normal => 0.0,
        };

        final scale = 1 + (breathing * 0.03) + pulseBoost;
        final glow = switch (widget.state) {
          SleepState.sleep => 42 + (alert * 12),
          SleepState.sleepy => 32 + (alert * 8),
          SleepState.normal => 28 + (breathing * 6),
        };

        final spread = switch (widget.state) {
          SleepState.sleep => 7 + (alert * 4),
          SleepState.sleepy => 5 + (alert * 2),
          SleepState.normal => 3 + (breathing * 1.5),
        };

        return Transform.scale(
          scale: scale,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: color.withValues(alpha: 0.42),
                        blurRadius: glow,
                        spreadRadius: spread,
                      ),
                    ],
                  ),
                ),
                Container(
                  width: widget.size * 0.76,
                  height: widget.size * 0.76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[
                        Colors.white.withValues(alpha: 0.94),
                        color.withValues(alpha: 0.88),
                        color.withValues(alpha: 0.55),
                      ],
                      stops: const <double>[0.0, 0.45, 1.0],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.72),
                      width: 1.4,
                    ),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: widget.size * 0.34,
                  height: widget.size * 0.34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.28),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _statusColor(SleepState state) {
    switch (state) {
      case SleepState.normal:
        return const Color(0xFF36E18A);
      case SleepState.sleepy:
        return const Color(0xFFFFBC42);
      case SleepState.sleep:
        return const Color(0xFFFF5A71);
    }
  }
}
