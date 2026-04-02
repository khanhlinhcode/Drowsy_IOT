import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/sleep_model.dart';
import '../providers/sleep_provider.dart';
import '../services/auth_service.dart';
import '../widgets/glass_card.dart';

class AnalyticsScreen extends StatelessWidget {
  const AnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SleepProvider>();
    final history = provider.history;

    final weeklyStats = _buildLast7Days(history);
    final todayStats = weeklyStats.isNotEmpty
        ? weeklyStats.last
        : _DayStat.empty();

    final distribution = provider.stateDistribution;
    final total = provider.totalEvents;

    final normalPct = total == 0
        ? 0.0
        : (distribution[SleepState.normal]! / total);
    final sleepyPct = total == 0
        ? 0.0
        : (distribution[SleepState.sleepy]! / total);
    final sleepPct = total == 0
        ? 0.0
        : (distribution[SleepState.sleep]! / total);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              Color(0xFF0A1425),
              Color(0xFF121E34),
              Color(0xFF091321),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    _RoundIconButton(
                      icon: CupertinoIcons.back,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Analytics',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    _RoundIconButton(
                      icon: CupertinoIcons.square_arrow_right,
                      onTap: () async {
                        await AuthService.instance.signOut();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    children: <Widget>[
                      GlassCard(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                        gradientColors: <Color>[
                          Colors.white.withValues(alpha: 0.20),
                          Colors.white.withValues(alpha: 0.08),
                        ],
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Realtime Summary',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: <Widget>[
                                _MetricChip(
                                  label: 'User',
                                  value: provider.userId,
                                ),
                                _MetricChip(
                                  label: 'Topic',
                                  value: provider.subscribedTopic,
                                ),
                                _MetricChip(
                                  label: 'Sleep Events',
                                  value: provider.totalSleepCount.toString(),
                                ),
                                _MetricChip(
                                  label: 'Fatigue',
                                  value:
                                      '${provider.fatiguePercentage.toStringAsFixed(1)}%',
                                ),
                                _MetricChip(
                                  label: 'Avg Confidence',
                                  value:
                                      '${(provider.averageConfidence * 100).toStringAsFixed(1)}%',
                                ),
                                _MetricChip(
                                  label: 'Latency',
                                  value: '${provider.latestLatencyMs} ms',
                                ),
                                _MetricChip(
                                  label: 'Network',
                                  value: provider.connectionQuality
                                      .toUpperCase(),
                                ),
                                _MetricChip(
                                  label: 'Samples',
                                  value: provider.totalEvents.toString(),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      GlassCard(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                        gradientColors: <Color>[
                          Colors.white.withValues(alpha: 0.20),
                          Colors.white.withValues(alpha: 0.08),
                        ],
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Daily Stats (Today)',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: _DailyCell(
                                    label: 'Total',
                                    value: todayStats.total.toString(),
                                  ),
                                ),
                                Expanded(
                                  child: _DailyCell(
                                    label: 'Normal',
                                    value: todayStats.normal.toString(),
                                  ),
                                ),
                                Expanded(
                                  child: _DailyCell(
                                    label: 'Sleepy',
                                    value: todayStats.sleepy.toString(),
                                  ),
                                ),
                                Expanded(
                                  child: _DailyCell(
                                    label: 'Sleep',
                                    value: todayStats.sleep.toString(),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      GlassCard(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                        gradientColors: <Color>[
                          Colors.white.withValues(alpha: 0.20),
                          Colors.white.withValues(alpha: 0.08),
                        ],
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Weekly Trend',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 10),
                            ...weeklyStats.map((day) {
                              final ratio = day.total == 0
                                  ? 0.0
                                  : (day.sleep + day.sleepy * 0.5) / day.total;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _TrendRow(
                                  dayLabel: day.label,
                                  total: day.total,
                                  ratio: ratio,
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      GlassCard(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                        gradientColors: <Color>[
                          Colors.white.withValues(alpha: 0.20),
                          Colors.white.withValues(alpha: 0.08),
                        ],
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'State Distribution',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 10),
                            _DistRow(
                              label: 'Normal',
                              pct: normalPct,
                              color: const Color(0xFF37D67A),
                            ),
                            const SizedBox(height: 8),
                            _DistRow(
                              label: 'Sleepy',
                              pct: sleepyPct,
                              color: const Color(0xFFFFA62B),
                            ),
                            const SizedBox(height: 8),
                            _DistRow(
                              label: 'Sleep',
                              pct: sleepPct,
                              color: const Color(0xFFFF4D5D),
                            ),
                          ],
                        ),
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

  static List<_DayStat> _buildLast7Days(List<SleepModel> history) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(const Duration(days: 6));

    final byDay = <DateTime, _DayStat>{
      for (var i = 0; i < 7; i++)
        start.add(Duration(days: i)): _DayStat(
          day: start.add(Duration(days: i)),
        ),
    };

    for (final item in history) {
      final day = DateTime(item.time.year, item.time.month, item.time.day);
      if (day.isBefore(start) || day.isAfter(today)) {
        continue;
      }

      final stat = byDay[day];
      if (stat == null) {
        continue;
      }

      stat.total += 1;
      switch (item.state) {
        case SleepState.normal:
          stat.normal += 1;
          break;
        case SleepState.sleepy:
          stat.sleepy += 1;
          break;
        case SleepState.sleep:
          stat.sleep += 1;
          break;
      }
    }

    return byDay.values.toList(growable: false);
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.32)),
        ),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _DailyCell extends StatelessWidget {
  const _DailyCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.white70,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _TrendRow extends StatelessWidget {
  const _TrendRow({
    required this.dayLabel,
    required this.total,
    required this.ratio,
  });

  final String dayLabel;
  final int total;
  final double ratio;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 34,
          child: Text(
            dayLabel,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: Colors.white.withValues(alpha: 0.12),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(0xFF7DD3FC),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 42,
          child: Text(
            total.toString(),
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _DistRow extends StatelessWidget {
  const _DistRow({required this.label, required this.pct, required this.color});

  final String label;
  final double pct;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final percent = (pct * 100).clamp(0, 100);

    return Row(
      children: <Widget>[
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: pct.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: Colors.white.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 48,
          child: Text(
            '${percent.toStringAsFixed(1)}%',
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _DayStat {
  _DayStat({required this.day});

  _DayStat.empty() : day = DateTime.now();

  final DateTime day;
  int total = 0;
  int normal = 0;
  int sleepy = 0;
  int sleep = 0;

  String get label {
    const labels = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return labels[(day.weekday - 1).clamp(0, 6)];
  }
}
