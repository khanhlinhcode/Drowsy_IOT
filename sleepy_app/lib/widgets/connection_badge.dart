import 'package:flutter/material.dart';

import '../services/mqtt_service.dart';

class ConnectionBadge extends StatefulWidget {
  const ConnectionBadge({super.key, required this.status});

  final MqttFeedStatus status;

  @override
  State<ConnectionBadge> createState() => _ConnectionBadgeState();
}

class _ConnectionBadgeState extends State<ConnectionBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dotController;

  @override
  void initState() {
    super.initState();
    _dotController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 920),
    );
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant ConnectionBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    if (_isTransient(widget.status)) {
      _dotController.repeat(reverse: true);
      return;
    }

    _dotController
      ..stop()
      ..value = 0;
  }

  bool _isTransient(MqttFeedStatus status) {
    return status == MqttFeedStatus.connecting ||
        status == MqttFeedStatus.reconnecting;
  }

  @override
  void dispose() {
    _dotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (label, color) = _meta(widget.status);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.20),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.56)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: color.withValues(alpha: 0.18),
            blurRadius: 14,
            spreadRadius: 1,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AnimatedBuilder(
            animation: _dotController,
            builder: (context, child) {
              final pulse = _isTransient(widget.status)
                  ? 0.8 + (_dotController.value * 0.4)
                  : 1.0;

              return Opacity(
                opacity: _isTransient(widget.status)
                    ? 0.55 + (_dotController.value * 0.45)
                    : 1.0,
                child: Transform.scale(scale: pulse, child: child),
              );
            },
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: color.withValues(alpha: 0.9),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  (String, Color) _meta(MqttFeedStatus status) {
    switch (status) {
      case MqttFeedStatus.connected:
        return ('Connected', const Color(0xFF4ADE80));
      case MqttFeedStatus.connecting:
        return ('Connecting', const Color(0xFFFACC15));
      case MqttFeedStatus.reconnecting:
        return ('Reconnecting', const Color(0xFFFFB020));
      case MqttFeedStatus.disconnected:
        return ('Disconnected', const Color(0xFFFB7185));
      case MqttFeedStatus.error:
        return ('Connection Error', const Color(0xFFEF4444));
    }
  }
}
