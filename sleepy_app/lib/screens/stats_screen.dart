import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/sleep_provider.dart';
import '../widgets/chart_widget.dart';
import '../widgets/glass_card.dart';
import '../widgets/stats_card.dart';

class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final history = context.select((SleepProvider p) => p.history);
    final sleepCount = context.select((SleepProvider p) => p.totalSleepCount);
    final avgConfidence = context.select(
      (SleepProvider p) => p.averageConfidence,
    );
    final totalSamples = history.length;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Color(0xFF080F21),
              Color(0xFF1A2042),
              Color(0xFF30204B),
            ],
            stops: <double>[0, 0.55, 1],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    _RoundIconButton(
                      icon: CupertinoIcons.back,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 12),
                    Hero(
                      tag: 'stats_nav_hero',
                      child: Material(
                        color: Colors.transparent,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              const Icon(
                                CupertinoIcons.chart_bar_alt_fill,
                                color: Colors.white,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Statistics',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    children: <Widget>[
                      GlassCard(
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                        gradientColors: <Color>[
                          Colors.white.withValues(alpha: 0.21),
                          Colors.white.withValues(alpha: 0.08),
                        ],
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Realtime Trend',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'State (0 / 0.5 / 1) and confidence over time',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Colors.white70,
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                            const SizedBox(height: 14),
                            SizedBox(
                              height: 320,
                              child: ChartWidget(data: history),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: StatsCard(
                              title: 'Sleep Count',
                              value: sleepCount.toString(),
                              subtitle: 'Critical events',
                              accent: const Color(0xFFFF5A71),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: StatsCard(
                              title: 'Avg Confidence',
                              value:
                                  '${(avgConfidence * 100).toStringAsFixed(1)}%',
                              subtitle: 'Model certainty',
                              accent: const Color(0xFF52A8FF),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      StatsCard(
                        title: 'Total Samples',
                        value: totalSamples.toString(),
                        subtitle: 'Realtime records in memory',
                        accent: const Color(0xFF36E18A),
                      ),
                    ],
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

class _RoundIconButton extends StatefulWidget {
  const _RoundIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_RoundIconButton> createState() => _RoundIconButtonState();
}

class _RoundIconButtonState extends State<_RoundIconButton> {
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
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOutCubic,
        scale: _pressed ? 0.94 : 1,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.32)),
          ),
          child: Icon(widget.icon, color: Colors.white),
        ),
      ),
    );
  }
}
