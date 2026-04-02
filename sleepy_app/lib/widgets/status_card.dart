import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/sleep_model.dart';
import '../services/mqtt_service.dart';
import 'animated_indicator.dart';
import 'connection_badge.dart';
import 'glass_card.dart';

class StatusCard extends StatelessWidget {
  const StatusCard({
    super.key,
    required this.state,
    required this.confidence,
    required this.connectionStatus,
    required this.isLoading,
    this.width,
    this.error,
    required this.onOpenStats,
  });

  final SleepState state;
  final double confidence;
  final MqttFeedStatus connectionStatus;
  final bool isLoading;
  final double? width;
  final String? error;
  final VoidCallback onOpenStats;

  @override
  Widget build(BuildContext context) {
    final safeConfidence = confidence.clamp(0.0, 1.0).toDouble();
    final stateColor = _stateColor(state);

    return GlassCard(
      width: width,
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
      gradientColors: <Color>[
        Colors.white.withValues(alpha: 0.22),
        Colors.white.withValues(alpha: 0.08),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: stateColor,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: stateColor.withValues(alpha: 0.9),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Driver Status',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
              const Spacer(),
              ConnectionBadge(status: connectionStatus),
            ],
          ),
          const SizedBox(height: 24),
          AnimatedIndicator(state: state),
          const SizedBox(height: 20),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 380),
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.92, end: 1).animate(animation),
                  child: child,
                ),
              );
            },
            child: Text(
              state.label,
              key: ValueKey<String>(state.label),
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Real-time monitoring',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Colors.white.withValues(alpha: 0.84),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Text(
                'Confidence',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                child: Text(
                  '${(safeConfidence * 100).toStringAsFixed(0)}%',
                  key: ValueKey<int>((safeConfidence * 1000).round()),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          _ConfidenceBar(value: safeConfidence, color: stateColor),
          if (isLoading) ...<Widget>[
            const SizedBox(height: 14),
            const CupertinoActivityIndicator(color: Colors.white),
          ],
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: error == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      key: ValueKey<String>(error!),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFFFFC9CE),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 18),
          _StatsButton(onTap: onOpenStats),
        ],
      ),
    );
  }

  Color _stateColor(SleepState status) {
    switch (status) {
      case SleepState.normal:
        return const Color(0xFF36E18A);
      case SleepState.sleepy:
        return const Color(0xFFFFBC42);
      case SleepState.sleep:
        return const Color(0xFFFF5A71);
    }
  }
}

class _ConfidenceBar extends StatelessWidget {
  const _ConfidenceBar({required this.value, required this.color});

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: Stack(
            children: <Widget>[
              Container(
                height: 10,
                width: constraints.maxWidth,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: value),
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutCubic,
                builder: (context, progress, child) {
                  return Container(
                    height: 10,
                    width: constraints.maxWidth * progress,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: LinearGradient(
                        colors: <Color>[
                          color.withValues(alpha: 0.95),
                          color.withValues(alpha: 0.35),
                        ],
                      ),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: color.withValues(alpha: 0.62),
                          blurRadius: 12,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatsButton extends StatefulWidget {
  const _StatsButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_StatsButton> createState() => _StatsButtonState();
}

class _StatsButtonState extends State<_StatsButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        scale: _pressed ? 0.97 : 1,
        child: Hero(
          tag: 'stats_nav_hero',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: <Widget>[
                const Icon(
                  CupertinoIcons.chart_bar_alt_fill,
                  size: 20,
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Statistics',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
