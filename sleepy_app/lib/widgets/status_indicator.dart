import 'package:flutter/material.dart';

import '../models/sleep_model.dart';

class StatusIndicator extends StatefulWidget {
  const StatusIndicator({super.key, required this.state, this.size = 108});

  final SleepState state;
  final double size;

  @override
  State<StatusIndicator> createState() => _StatusIndicatorState();
}

class _StatusIndicatorState extends State<StatusIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant StatusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _syncPulse();
    }
  }

  void _syncPulse() {
    if (widget.state == SleepState.sleep) {
      _pulseController.repeat(reverse: true);
      return;
    }

    _pulseController.stop();
    _pulseController.animateTo(0);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(widget.state);

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final scale = widget.state == SleepState.sleep
            ? 1 + (_pulseController.value * 0.08)
            : 1.0;

        return Transform.scale(scale: scale, child: child);
      },
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            AnimatedContainer(
              duration: const Duration(milliseconds: 340),
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: color.withValues(alpha: 0.42),
                    blurRadius: widget.state == SleepState.sleep ? 34 : 24,
                    spreadRadius: widget.state == SleepState.sleep ? 8 : 4,
                  ),
                ],
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 340),
              width: widget.size * 0.72,
              height: widget.size * 0.72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[
                    color.withValues(alpha: 0.95),
                    color.withValues(alpha: 0.55),
                  ],
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.7),
                  width: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(SleepState state) {
    switch (state) {
      case SleepState.normal:
        return const Color(0xFF37D67A);
      case SleepState.sleepy:
        return const Color(0xFFFFA62B);
      case SleepState.sleep:
        return const Color(0xFFFF4D5D);
    }
  }
}
