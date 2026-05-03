import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/sleep_model.dart';
import '../services/mqtt_service.dart';
import 'animated_indicator.dart';
import 'connection_badge.dart';
import 'glass_card.dart';

class StatusCard extends StatefulWidget {
  const StatusCard({
    super.key,
    required this.state,
    required this.confidence,
    required this.connectionStatus,
    required this.isLoading,
    required this.piStatusLabel,
    required this.detectionArmed,
    required this.faceInFrame,
    required this.faceLocked,
    required this.driveDurationLabel,
    required this.sleepGapLabel,
    this.fatigue,
    this.signal,
    this.width,
    this.error,
    required this.onOpenStats,
  });

  final SleepState state;
  final double confidence;
  final MqttFeedStatus connectionStatus;
  final bool isLoading;
  final String piStatusLabel;
  final bool detectionArmed;
  final bool faceInFrame;
  final bool faceLocked;
  final String driveDurationLabel;
  final String sleepGapLabel;
  final int? fatigue;
  final int? signal;
  final double? width;
  final String? error;
  final VoidCallback onOpenStats;

  @override
  State<StatusCard> createState() => _StatusCardState();
}

class _StatusCardState extends State<StatusCard> {
  int _sectionIndex = 0;

  void _setSection(int? section) {
    if (section == null || section == _sectionIndex) {
      return;
    }
    setState(() {
      _sectionIndex = section;
    });
  }

  @override
  Widget build(BuildContext context) {
    final safeConfidence = widget.confidence.clamp(0.0, 1.0).toDouble();
    final stateColor = _stateColor(widget.state);
    final confidencePercent = (safeConfidence * 100).toStringAsFixed(0);
    final confidenceMeta = _confidenceMeta(safeConfidence);

    return GlassCard(
      width: widget.width,
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
      gradientColors: <Color>[
        Colors.white.withValues(alpha: 0.14),
        Colors.white.withValues(alpha: 0.04),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // ── Header: Title + Connection Badge ───────────────────────
          LayoutBuilder(
            builder: (context, constraints) {
              final compactHeader = constraints.maxWidth < 350;

              final titleRow = Row(
                children: <Widget>[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: stateColor,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: stateColor.withValues(alpha: 0.8),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Driver Status',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ),
                ],
              );

              if (compactHeader) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    titleRow,
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ConnectionBadge(status: widget.connectionStatus),
                    ),
                  ],
                );
              }

              return Row(
                children: <Widget>[
                  Expanded(child: titleRow),
                  const SizedBox(width: 8),
                  ConnectionBadge(status: widget.connectionStatus),
                ],
              );
            },
          ),
          const SizedBox(height: 28),

          // ── Animated Indicator ─────────────────────────────────────
          AnimatedIndicator(state: widget.state),
          const SizedBox(height: 24),

          // ── State Label ────────────────────────────────────────────
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 380),
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.12),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _stateLabel(widget.state),
                key: ValueKey<String>(_stateLabel(widget.state)),
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 28,
                  letterSpacing: 1.2,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _stateSubLabel(widget.state),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.40),
              fontWeight: FontWeight.w500,
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'Pi: ${widget.piStatusLabel}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.35),
              fontWeight: FontWeight.w500,
              fontSize: 11,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),

          // ── Section Tabs ───────────────────────────────────────────
          _SectionTabs(value: _sectionIndex, onChanged: _setSection),
          const SizedBox(height: 14),

          // ── Section Chips ──────────────────────────────────────────
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: Wrap(
              key: ValueKey<int>(_sectionIndex),
              alignment: WrapAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: _buildSectionChips(
                section: _sectionIndex,
                confidencePercent: confidencePercent,
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── Confidence Bar ─────────────────────────────────────────
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Confidence',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: confidenceMeta.$2.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  confidenceMeta.$1,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: confidenceMeta.$2.withValues(alpha: 0.85),
                    fontWeight: FontWeight.w700,
                    fontSize: 10,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                child: Text(
                  '$confidencePercent%',
                  key: ValueKey<String>('conf-$confidencePercent'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    fontFeatures: <FontFeature>[
                      const FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _ConfidenceBar(value: safeConfidence, color: stateColor),

          // ── Loading indicator ──────────────────────────────────────
          if (widget.isLoading) ...<Widget>[
            const SizedBox(height: 16),
            const CupertinoActivityIndicator(color: Colors.white),
          ],

          // ── Error message ──────────────────────────────────────────
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: widget.error == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: const Color(0xFFEF4444)
                              .withValues(alpha: 0.15),
                        ),
                      ),
                      child: Text(
                        widget.error!,
                        key: ValueKey<String>(widget.error!),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFFFFC9CE),
                          fontWeight: FontWeight.w500,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 16),

          // ── Fatigue Meter ───────────────────────────────────────────
          if (widget.fatigue != null) ...<Widget>[
            _FatigueMeter(fatigue: widget.fatigue!.clamp(0, 100)),
            const SizedBox(height: 16),
          ],

          // ── Stats Button ───────────────────────────────────────────
          _StatsButton(onTap: widget.onOpenStats),
        ],
      ),
    );
  }

  List<Widget> _buildSectionChips({
    required int section,
    required String confidencePercent,
  }) {
    switch (section) {
      case 0:
        return <Widget>[
          _InfoChip(
            icon: CupertinoIcons.shield_fill,
            label: widget.detectionArmed ? 'Ready' : 'Arming',
            color: widget.detectionArmed
                ? const Color(0xFF34D399)
                : const Color(0xFFFBBF24),
          ),
          _InfoChip(
            icon: CupertinoIcons.timer,
            label: widget.driveDurationLabel,
            color: const Color(0xFF60A5FA),
          ),
          _InfoChip(
            icon: CupertinoIcons.clock,
            label: 'Gap ${widget.sleepGapLabel}',
            color: const Color(0xFFFB923C),
          ),
        ];
      case 1:
        return <Widget>[
          _InfoChip(
            icon: CupertinoIcons.person_crop_circle,
            label: widget.faceInFrame ? 'Face ✓' : 'No Face',
            color: widget.faceInFrame
                ? const Color(0xFF34D399)
                : const Color(0xFFF87171),
          ),
          _InfoChip(
            icon: CupertinoIcons.lock_fill,
            label: widget.faceLocked ? 'Locked' : 'Scanning',
            color: widget.faceLocked
                ? const Color(0xFF60A5FA)
                : const Color(0xFF9CA3AF),
          ),
          if (widget.signal != null)
            _InfoChip(
              icon: CupertinoIcons.antenna_radiowaves_left_right,
              label: 'Signal ${widget.signal}',
              color: Colors.white.withValues(alpha: 0.60),
            ),
        ];
      case 2:
      default:
        return <Widget>[
          _InfoChip(
            icon: CupertinoIcons.chart_bar,
            label: '$confidencePercent%',
            color: const Color(0xFF60A5FA),
          ),
          if (widget.fatigue != null)
            _InfoChip(
              icon: CupertinoIcons.battery_25,
              label: 'Fatigue ${widget.fatigue!.clamp(0, 100)}',
              color: const Color(0xFFFBBF24),
            ),
          _InfoChip(
            icon: CupertinoIcons.doc_text,
            label: widget.piStatusLabel,
            color: const Color(0xFFA78BFA),
          ),
        ];
    }
  }

  Color _stateColor(SleepState status) {
    switch (status) {
      case SleepState.normal:
        return const Color(0xFF34D399);
      case SleepState.sleepy:
        return const Color(0xFFFBBF24);
      case SleepState.sleep:
        return const Color(0xFFF87171);
    }
  }

  String _stateLabel(SleepState status) {
    switch (status) {
      case SleepState.normal:
        return 'NORMAL';
      case SleepState.sleepy:
        return 'SLEEPY';
      case SleepState.sleep:
        return 'DROWSY';
    }
  }

  String _stateSubLabel(SleepState status) {
    switch (status) {
      case SleepState.normal:
        return 'Bình thường • Tỉnh táo';
      case SleepState.sleepy:
        return 'Buồn ngủ • Cần chú ý';
      case SleepState.sleep:
        return 'Ngủ gật • Nguy hiểm!';
    }
  }

  (String, Color) _confidenceMeta(double score) {
    if (score >= 0.86) {
      return ('Very High', const Color(0xFF34D399));
    }
    if (score >= 0.68) {
      return ('High', const Color(0xFF60A5FA));
    }
    if (score >= 0.45) {
      return ('Medium', const Color(0xFFFBBF24));
    }
    return ('Low', const Color(0xFFFB923C));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section Tabs — iOS segmented control style
// ─────────────────────────────────────────────────────────────────────────────
class _SectionTabs extends StatelessWidget {
  const _SectionTabs({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: CupertinoSlidingSegmentedControl<int>(
        groupValue: value,
        thumbColor: Colors.white.withValues(alpha: 0.14),
        backgroundColor: Colors.transparent,
        onValueChanged: onChanged,
        children: <int, Widget>{
          0: _segmentText('Overview'),
          1: _segmentText('Face'),
          2: _segmentText('Metrics'),
        },
      ),
    );
  }

  static Widget _segmentText(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Info Chip — compact data chip with icon
// ─────────────────────────────────────────────────────────────────────────────
class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: color.withValues(alpha: 0.15),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12, color: color.withValues(alpha: 0.75)),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.80),
              fontWeight: FontWeight.w600,
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Confidence Bar
// ─────────────────────────────────────────────────────────────────────────────
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
                height: 6,
                width: constraints.maxWidth,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: value),
                duration: const Duration(milliseconds: 480),
                curve: Curves.easeOutCubic,
                builder: (context, progress, child) {
                  return Container(
                    height: 6,
                    width: constraints.maxWidth * progress,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: LinearGradient(
                        colors: <Color>[
                          color,
                          color.withValues(alpha: 0.40),
                        ],
                      ),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: color.withValues(alpha: 0.40),
                          blurRadius: 8,
                          spreadRadius: 0,
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

// ─────────────────────────────────────────────────────────────────────────────
// Stats Button
// ─────────────────────────────────────────────────────────────────────────────
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.10),
                width: 0.5,
              ),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  CupertinoIcons.chart_bar_alt_fill,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.65),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Statistics',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.80),
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                Icon(
                  CupertinoIcons.chevron_right,
                  size: 14,
                  color: Colors.white.withValues(alpha: 0.30),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fatigue Meter — visual gradient bar with icon
// ─────────────────────────────────────────────────────────────────────────────
class _FatigueMeter extends StatelessWidget {
  const _FatigueMeter({required this.fatigue});

  final int fatigue;

  @override
  Widget build(BuildContext context) {
    final percent = fatigue / 100.0;
    final fatigueColor = _fatigueColor(fatigue);
    final fatigueLabel = _fatigueLabel(fatigue);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.battery_4_bar_rounded,
                size: 16,
                color: fatigueColor.withValues(alpha: 0.80),
              ),
              const SizedBox(width: 8),
              Text(
                'Fatigue Level',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: fatigueColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  fatigueLabel,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: fatigueColor.withValues(alpha: 0.90),
                    fontWeight: FontWeight.w700,
                    fontSize: 10,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$fatigue%',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  fontFeatures: <FontFeature>[
                    const FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Gradient bar
          LayoutBuilder(
            builder: (context, constraints) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: Stack(
                  children: <Widget>[
                    // Background
                    Container(
                      height: 8,
                      width: constraints.maxWidth,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    // Fill
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: percent),
                      duration: const Duration(milliseconds: 600),
                      curve: Curves.easeOutCubic,
                      builder: (context, progress, child) {
                        return Container(
                          height: 8,
                          width: constraints.maxWidth * progress,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            gradient: LinearGradient(
                              colors: <Color>[
                                const Color(0xFF34D399),
                                const Color(0xFFFBBF24),
                                fatigueColor,
                              ],
                            ),
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: fatigueColor.withValues(alpha: 0.40),
                                blurRadius: 8,
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
          ),
        ],
      ),
    );
  }

  Color _fatigueColor(int value) {
    if (value >= 70) return const Color(0xFFF87171);
    if (value >= 40) return const Color(0xFFFBBF24);
    return const Color(0xFF34D399);
  }

  String _fatigueLabel(int value) {
    if (value >= 80) return 'Nguy hiểm';
    if (value >= 60) return 'Mệt mỏi';
    if (value >= 40) return 'Chú ý';
    if (value >= 20) return 'Bình thường';
    return 'Tốt';
  }
}
