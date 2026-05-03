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
    final meta = _meta(widget.status);
    final color = meta.color;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      constraints: const BoxConstraints(maxWidth: 140),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: color.withValues(alpha: 0.20),
          width: 0.5,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final label = constraints.maxWidth < 120
              ? meta.compactLabel
              : meta.fullLabel;
          return Row(
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
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: color.withValues(alpha: 0.70),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.70),
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  _BadgeMeta _meta(MqttFeedStatus status) {
    switch (status) {
      case MqttFeedStatus.connected:
        return const _BadgeMeta(
          fullLabel: 'Connected',
          compactLabel: 'Online',
          color: Color(0xFF34D399),
        );
      case MqttFeedStatus.connecting:
        return const _BadgeMeta(
          fullLabel: 'Connecting...',
          compactLabel: 'Waiting',
          color: Color(0xFFFBBF24),
        );
      case MqttFeedStatus.reconnecting:
        return const _BadgeMeta(
          fullLabel: 'Reconnecting',
          compactLabel: 'Retry',
          color: Color(0xFFFB923C),
        );
      case MqttFeedStatus.disconnected:
        return const _BadgeMeta(
          fullLabel: 'Disconnected',
          compactLabel: 'Offline',
          color: Color(0xFFF87171),
        );
      case MqttFeedStatus.error:
        return const _BadgeMeta(
          fullLabel: 'Error',
          compactLabel: 'Error',
          color: Color(0xFFEF4444),
        );
    }
  }
}

class _BadgeMeta {
  const _BadgeMeta({
    required this.fullLabel,
    required this.compactLabel,
    required this.color,
  });

  final String fullLabel;
  final String compactLabel;
  final Color color;
}
