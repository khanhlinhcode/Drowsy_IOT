import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/sleep_model.dart';
import '../providers/sleep_provider.dart';
import '../services/auth_service.dart';
import '../widgets/glass_card.dart';

class AnalyticsScreen extends StatelessWidget {
  const AnalyticsScreen({super.key, this.showBackButton = true});

  final bool showBackButton;

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
              Color(0xFF070E1A),
              Color(0xFF0E1728),
              Color(0xFF070E1A),
            ],
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
                        'Analytics',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 20,
                          letterSpacing: -0.3,
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
                const SizedBox(height: 16),

                // ── Content ─────────────────────────────────────────
                Expanded(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 100),
                    children: <Widget>[
                      // ── Realtime Summary ──────────────────────────
                      _SectionHeader(
                        title: 'Realtime Summary',
                        icon: CupertinoIcons.graph_circle,
                      ),
                      const SizedBox(height: 8),
                      GlassCard(
                        padding: const EdgeInsets.all(16),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: <Widget>[
                            _MetricTile(
                              label: 'User',
                              value: provider.userId,
                              icon: CupertinoIcons.person,
                            ),
                            _MetricTile(
                              label: 'Topic',
                              value: provider.subscribedTopic,
                              icon: CupertinoIcons.antenna_radiowaves_left_right,
                            ),
                            _MetricTile(
                              label: 'Sleep Events',
                              value: provider.totalSleepCount.toString(),
                              icon: CupertinoIcons.exclamationmark_triangle,
                            ),
                            _MetricTile(
                              label: 'Fatigue',
                              value:
                                  '${provider.fatiguePercentage.toStringAsFixed(1)}%',
                              icon: CupertinoIcons.battery_25,
                            ),
                            _MetricTile(
                              label: 'Confidence',
                              value:
                                  '${(provider.averageConfidence * 100).toStringAsFixed(1)}%',
                              icon: CupertinoIcons.chart_bar,
                            ),
                            _MetricTile(
                              label: 'Latency',
                              value: '${provider.latestLatencyMs} ms',
                              icon: CupertinoIcons.timer,
                            ),
                            _MetricTile(
                              label: 'Drive Time',
                              value: provider.driveDurationLabel,
                              icon: CupertinoIcons.car,
                            ),
                            _MetricTile(
                              label: 'Sleep Gap',
                              value: provider.lastSleepGapLabel,
                              icon: CupertinoIcons.clock,
                            ),
                            _MetricTile(
                              label: 'Network',
                              value: provider.connectionQuality.toUpperCase(),
                              icon: CupertinoIcons.wifi,
                            ),
                            _MetricTile(
                              label: 'Samples',
                              value: provider.totalEvents.toString(),
                              icon: CupertinoIcons.doc_text,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // ── Today Stats ───────────────────────────────
                      _SectionHeader(
                        title: 'Today',
                        icon: CupertinoIcons.calendar_today,
                      ),
                      const SizedBox(height: 8),
                      GlassCard(
                        padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: _DailyCell(
                                label: 'Total',
                                value: todayStats.total.toString(),
                                color: const Color(0xFF60A5FA),
                              ),
                            ),
                            _VerticalDivider(),
                            Expanded(
                              child: _DailyCell(
                                label: 'Normal',
                                value: todayStats.normal.toString(),
                                color: const Color(0xFF34D399),
                              ),
                            ),
                            _VerticalDivider(),
                            Expanded(
                              child: _DailyCell(
                                label: 'Sleepy',
                                value: todayStats.sleepy.toString(),
                                color: const Color(0xFFFBBF24),
                              ),
                            ),
                            _VerticalDivider(),
                            Expanded(
                              child: _DailyCell(
                                label: 'Sleep',
                                value: todayStats.sleep.toString(),
                                color: const Color(0xFFF87171),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // ── Weekly Trend ──────────────────────────────
                      _SectionHeader(
                        title: 'Weekly Trend',
                        icon: CupertinoIcons.chart_bar_alt_fill,
                      ),
                      const SizedBox(height: 8),
                      GlassCard(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                        child: Column(
                          children: <Widget>[
                            ...weeklyStats.map((day) {
                              final ratio = day.total == 0
                                  ? 0.0
                                  : (day.sleep + day.sleepy * 0.5) / day.total;
                              final isToday = day == weeklyStats.last;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _TrendRow(
                                  dayLabel: day.label,
                                  total: day.total,
                                  ratio: ratio,
                                  isToday: isToday,
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // ── State Distribution ────────────────────────
                      _SectionHeader(
                        title: 'Distribution',
                        icon: CupertinoIcons.chart_pie,
                      ),
                      const SizedBox(height: 8),
                      GlassCard(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                        child: Column(
                          children: <Widget>[
                            _DistRow(
                              label: 'Normal',
                              pct: normalPct,
                              color: const Color(0xFF34D399),
                            ),
                            const SizedBox(height: 12),
                            _DistRow(
                              label: 'Sleepy',
                              pct: sleepyPct,
                              color: const Color(0xFFFBBF24),
                            ),
                            const SizedBox(height: 12),
                            _DistRow(
                              label: 'Sleep',
                              pct: sleepPct,
                              color: const Color(0xFFF87171),
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

// ─────────────────────────────────────────────────────────────────────────────
// Section Header
// ─────────────────────────────────────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        children: <Widget>[
          Icon(
            icon,
            size: 15,
            color: Colors.white.withValues(alpha: 0.35),
          ),
          const SizedBox(width: 7),
          Text(
            title,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.45),
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Round Icon Button
// ─────────────────────────────────────────────────────────────────────────────
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
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
          icon,
          color: Colors.white.withValues(alpha: 0.70),
          size: 18,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Metric Tile — compact data display with icon
// ─────────────────────────────────────────────────────────────────────────────
class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            icon,
            size: 14,
            color: Colors.white.withValues(alpha: 0.30),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.40),
                  fontWeight: FontWeight.w600,
                  fontSize: 10,
                ),
              ),
              const SizedBox(height: 2),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 100),
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Daily Cell — today stats
// ─────────────────────────────────────────────────────────────────────────────
class _DailyCell extends StatelessWidget {
  const _DailyCell({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 22,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: color.withValues(alpha: 0.65),
            fontWeight: FontWeight.w600,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _VerticalDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 0.5,
      height: 32,
      color: Colors.white.withValues(alpha: 0.10),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Trend Row — weekly bar chart row
// ─────────────────────────────────────────────────────────────────────────────
class _TrendRow extends StatelessWidget {
  const _TrendRow({
    required this.dayLabel,
    required this.total,
    required this.ratio,
    this.isToday = false,
  });

  final String dayLabel;
  final int total;
  final double ratio;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 32,
          child: Text(
            dayLabel,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: isToday
                  ? const Color(0xFF60A5FA)
                  : Colors.white.withValues(alpha: 0.45),
              fontWeight: isToday ? FontWeight.w700 : FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: ratio.clamp(0.0, 1.0)),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) {
                return LinearProgressIndicator(
                  value: value,
                  minHeight: 6,
                  backgroundColor: Colors.white.withValues(alpha: 0.06),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isToday
                        ? const Color(0xFF60A5FA)
                        : const Color(0xFF60A5FA).withValues(alpha: 0.50),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 36,
          child: Text(
            total.toString(),
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.65),
              fontWeight: FontWeight.w700,
              fontSize: 12,
              fontFeatures: <FontFeature>[
                const FontFeature.tabularFigures(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Distribution Row
// ─────────────────────────────────────────────────────────────────────────────
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
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 60,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.60),
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: pct.clamp(0.0, 1.0)),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) {
                return LinearProgressIndicator(
                  value: value,
                  minHeight: 6,
                  backgroundColor: Colors.white.withValues(alpha: 0.06),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                );
              },
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 44,
          child: Text(
            '${percent.toStringAsFixed(1)}%',
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.70),
              fontWeight: FontWeight.w700,
              fontSize: 12,
              fontFeatures: <FontFeature>[
                const FontFeature.tabularFigures(),
              ],
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
