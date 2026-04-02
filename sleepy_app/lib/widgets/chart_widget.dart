import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/sleep_model.dart';

class ChartWidget extends StatelessWidget {
  const ChartWidget({super.key, required this.data});

  static const int _maxRenderedPoints = 120;

  final List<SleepModel> data;

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return Center(
        child: Text(
          'Waiting for incoming data...',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
        ),
      );
    }

    final plottedData = _downsample(data, maxPoints: _maxRenderedPoints);

    final stateSpots = plottedData
        .asMap()
        .entries
        .map(
          (entry) => FlSpot(entry.key.toDouble(), entry.value.state.chartValue),
        )
        .toList(growable: false);

    final confidenceSpots = plottedData
        .asMap()
        .entries
        .map((entry) => FlSpot(entry.key.toDouble(), entry.value.confidence))
        .toList(growable: false);

    final maxX = stateSpots.length > 1 ? stateSpots.length.toDouble() - 1 : 1.0;

    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            _LegendDot(color: const Color(0xFFFB7185), label: 'State'),
            const SizedBox(width: 14),
            _LegendDot(color: const Color(0xFF7DD3FC), label: 'Confidence'),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: maxX,
              minY: 0,
              maxY: 1,
              borderData: FlBorderData(show: false),
              clipData: const FlClipData.all(),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: 0.5,
                getDrawingHorizontalLine: (_) {
                  return FlLine(
                    color: Colors.white.withValues(alpha: 0.14),
                    strokeWidth: 1,
                  );
                },
              ),
              lineTouchData: LineTouchData(
                enabled: true,
                touchTooltipData: LineTouchTooltipData(
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  tooltipPadding: const EdgeInsets.all(10),
                  getTooltipItems: (touchedSpots) {
                    return touchedSpots
                        .map((spot) {
                          final index = spot.x.toInt().clamp(
                            0,
                            plottedData.length - 1,
                          );
                          final model = plottedData[index];
                          final hh = model.time.hour.toString().padLeft(2, '0');
                          final mm = model.time.minute.toString().padLeft(
                            2,
                            '0',
                          );

                          return LineTooltipItem(
                            '${model.state.label} | ${(model.confidence * 100).toStringAsFixed(0)}% | $hh:$mm',
                            const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          );
                        })
                        .toList(growable: false);
                  },
                ),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 60,
                    interval: 0.5,
                    getTitlesWidget: (value, meta) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          _leftLabel(value),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 30,
                    interval: _bottomInterval(plottedData.length),
                    getTitlesWidget: (value, meta) {
                      final index = value.toInt();
                      if (index < 0 || index >= plottedData.length) {
                        return const SizedBox.shrink();
                      }

                      final time = plottedData[index].time;
                      final hh = time.hour.toString().padLeft(2, '0');
                      final mm = time.minute.toString().padLeft(2, '0');

                      return Text(
                        '$hh:$mm',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineBarsData: <LineChartBarData>[
                LineChartBarData(
                  isCurved: true,
                  curveSmoothness: 0.22,
                  barWidth: 3.5,
                  isStrokeCapRound: true,
                  spots: stateSpots,
                  dotData: const FlDotData(show: false),
                  gradient: const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: <Color>[
                      Color(0xFF34D399),
                      Color(0xFFF97316),
                      Color(0xFFFB7185),
                    ],
                  ),
                  belowBarData: BarAreaData(
                    show: true,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        const Color(0xFFFB7185).withValues(alpha: 0.30),
                        const Color(0xFF0F172A).withValues(alpha: 0.03),
                      ],
                    ),
                  ),
                ),
                LineChartBarData(
                  isCurved: true,
                  curveSmoothness: 0.18,
                  barWidth: 2.4,
                  spots: confidenceSpots,
                  color: const Color(0xFF7DD3FC),
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(show: false),
                ),
              ],
            ),
            duration: const Duration(milliseconds: 620),
            curve: Curves.easeOutCubic,
          ),
        ),
      ],
    );
  }

  static List<SleepModel> _downsample(
    List<SleepModel> source, {
    required int maxPoints,
  }) {
    if (source.length <= maxPoints) {
      return source;
    }

    if (maxPoints <= 2) {
      return <SleepModel>[source.first, source.last];
    }

    final result = <SleepModel>[source.first];
    final middleSlots = maxPoints - 2;
    final span = (source.length - 2) / middleSlots;

    for (var bucketIndex = 0; bucketIndex < middleSlots; bucketIndex++) {
      final start = 1 + (bucketIndex * span).floor();
      var end = 1 + ((bucketIndex + 1) * span).floor();

      if (end <= start) {
        end = start + 1;
      }
      if (end > source.length - 1) {
        end = source.length - 1;
      }
      if (start >= source.length - 1) {
        break;
      }

      SleepModel best = source[start];
      var bestScore = -1.0;

      final previous = result.last;
      final prevState = previous.state.chartValue;
      final prevConfidence = previous.confidence;

      for (var i = start; i < end; i++) {
        final candidate = source[i];
        final score =
            (candidate.state.chartValue - prevState).abs() * 0.7 +
            (candidate.confidence - prevConfidence).abs() * 0.3;

        if (score > bestScore) {
          bestScore = score;
          best = candidate;
        }
      }

      result.add(best);
    }

    result.add(source.last);

    if (result.length <= maxPoints) {
      return result;
    }

    // Safety trim when rounding creates one extra sample.
    return result.sublist(result.length - maxPoints);
  }

  static String _leftLabel(double value) {
    if ((value - 0).abs() < 0.01) {
      return '0 Normal';
    }
    if ((value - 0.5).abs() < 0.01) {
      return '0.5 Sleepy';
    }
    if ((value - 1).abs() < 0.01) {
      return '1 Sleep';
    }
    return '';
  }

  static double _bottomInterval(int length) {
    if (length <= 8) {
      return 1;
    }
    if (length <= 24) {
      return 3;
    }
    if (length <= 72) {
      return 8;
    }
    return 16;
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.white70,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
