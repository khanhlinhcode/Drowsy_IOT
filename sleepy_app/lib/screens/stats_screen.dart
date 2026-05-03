import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/sleep_provider.dart';
import '../widgets/chart_widget.dart';
import '../widgets/glass_card.dart';
import '../widgets/stats_card.dart';

class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key, this.showBackButton = true});

  final bool showBackButton;

  @override
  Widget build(BuildContext context) {
    final history = context.select((SleepProvider p) => p.history);
    final sleepCount = context.select((SleepProvider p) => p.totalSleepCount);
    final avgConfidence = context.select(
      (SleepProvider p) => p.averageConfidence,
    );
    final driveDuration = context.select(
      (SleepProvider p) => p.driveDurationLabel,
    );
    final sleepGap = context.select((SleepProvider p) => p.lastSleepGapLabel);
    final totalSamples = history.length;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Color(0xFF070E1A),
              Color(0xFF111B32),
              Color(0xFF1E1838),
            ],
            stops: <double>[0, 0.55, 1],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              children: <Widget>[
                // ── Header ──────────────────────────────────────────
                Row(
                  children: <Widget>[
                    if (showBackButton)
                      _RoundIconButton(
                        icon: CupertinoIcons.back,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    if (showBackButton) const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Statistics',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 20,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── Content ─────────────────────────────────────────
                Expanded(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 100),
                    children: <Widget>[
                      // Chart Card
                      GlassCard(
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: const Color(0xFF60A5FA),
                                    boxShadow: <BoxShadow>[
                                      BoxShadow(
                                        color: const Color(0xFF60A5FA)
                                            .withValues(alpha: 0.50),
                                        blurRadius: 6,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Realtime Trend',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 16,
                                      ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'State & confidence over time',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color:
                                        Colors.white.withValues(alpha: 0.35),
                                    fontWeight: FontWeight.w500,
                                    fontSize: 11,
                                  ),
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              height: 300,
                              child: ChartWidget(data: history),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Stats Grid
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: StatsCard(
                              title: 'Sleep Events',
                              value: sleepCount.toString(),
                              subtitle: 'Critical drowsy detections',
                              accent: const Color(0xFFF87171),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: StatsCard(
                              title: 'Avg Confidence',
                              value:
                                  '${(avgConfidence * 100).toStringAsFixed(1)}%',
                              subtitle: 'Model certainty level',
                              accent: const Color(0xFF60A5FA),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: StatsCard(
                              title: 'Drive Time',
                              value: driveDuration,
                              subtitle: 'Current trip duration',
                              accent: const Color(0xFF34D399),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: StatsCard(
                              title: 'Sleep Gap',
                              value: sleepGap,
                              subtitle: 'Between last 2 events',
                              accent: const Color(0xFFFBBF24),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      StatsCard(
                        title: 'Total Samples',
                        value: totalSamples.toString(),
                        subtitle: 'Realtime records in memory',
                        accent: const Color(0xFF34D399),
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
        scale: _pressed ? 0.92 : 1,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.10),
              width: 0.5,
            ),
          ),
          child: Icon(
            widget.icon,
            color: Colors.white.withValues(alpha: 0.70),
            size: 18,
          ),
        ),
      ),
    );
  }
}
