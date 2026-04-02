import 'package:flutter/material.dart';

import 'glass_card.dart';

class StatsCard extends StatelessWidget {
  const StatsCard({
    super.key,
    required this.title,
    required this.value,
    required this.accent,
    this.subtitle,
  });

  final String title;
  final String value;
  final String? subtitle;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      borderRadius: 20,
      gradientColors: <Color>[
        Colors.white.withValues(alpha: 0.17),
        Colors.white.withValues(alpha: 0.07),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
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
              value,
              key: ValueKey<String>(value),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white60,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Container(
            height: 4,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: LinearGradient(
                colors: <Color>[
                  accent.withValues(alpha: 0.9),
                  accent.withValues(alpha: 0.24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
