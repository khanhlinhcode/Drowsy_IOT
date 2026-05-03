import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/sleep_model.dart';
import '../providers/sleep_provider.dart';
import '../widgets/status_card.dart';
import 'stats_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.onOpenStatsRequested});

  final VoidCallback? onOpenStatsRequested;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isAlertVisible = false;
  bool _isRestAlertVisible = false;
  SleepState? _lastStateForHaptic;

  @override
  Widget build(BuildContext context) {
    final current = context.select((SleepProvider p) => p.current);
    final isLoading = context.select((SleepProvider p) => p.isLoading);
    final connectionStatus = context.select(
      (SleepProvider p) => p.connectionStatus,
    );
    final error = context.select((SleepProvider p) => p.error);
    final shouldShowSleepAlert = context.select(
      (SleepProvider p) => p.shouldShowSleepAlert,
    );
    final shouldShowRestAlert = context.select(
      (SleepProvider p) => p.shouldShowRestAlert,
    );

    final currentState = current?.state ?? SleepState.normal;
    final confidence = current?.confidence ?? 0;
    final piStatusLabel = context.select(
      (SleepProvider p) => p.currentRawStatus,
    );
    final detectionArmed = context.select(
      (SleepProvider p) => p.isDetectionArmed,
    );
    final fatigue = context.select((SleepProvider p) => p.currentFatigue);
    final signal = context.select((SleepProvider p) => p.currentSignal);
    final faceInFrame = context.select((SleepProvider p) => p.isFaceInFrame);
    final faceLocked = context.select((SleepProvider p) => p.isFaceLocked);
    final driveDurationLabel = context.select(
      (SleepProvider p) => p.driveDurationLabel,
    );
    final sleepGapLabel = context.select(
      (SleepProvider p) => p.lastSleepGapLabel,
    );
    final recentSleepEvents2m = context.select(
      (SleepProvider p) => p.recentSleepEvents2m,
    );
    final provider = context.read<SleepProvider>();
    _triggerHapticOnStateChange(currentState);
    _showSleepAlertIfNeeded(
      provider,
      shouldShowSleepAlert,
      confidence,
      piStatusLabel,
      fatigue,
    );
    _showRestAlertIfNeeded(
      provider,
      shouldShowRestAlert,
      recentSleepEvents2m,
      sleepGapLabel,
    );

    return Scaffold(
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 640),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: _backgroundGradient(currentState),
            stops: const <double>[0, 0.56, 1],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth = math.min(constraints.maxWidth - 32, 440.0);

              return Stack(
                children: <Widget>[
                  // Ambient glow blobs
                  Positioned(
                    top: -100,
                    left: -80,
                    child: _GlowBlob(
                      color: Colors.white.withValues(alpha: 0.08),
                      size: 240,
                    ),
                  ),
                  Positioned(
                    top: constraints.maxHeight * 0.25,
                    right: -70,
                    child: _GlowBlob(
                      color: _stateColor(currentState).withValues(alpha: 0.12),
                      size: 220,
                    ),
                  ),
                  Positioned(
                    bottom: -110,
                    left: -50,
                    child: _GlowBlob(
                      color: const Color(0xFF8B5CF6).withValues(alpha: 0.10),
                      size: 260,
                    ),
                  ),
                  // Content
                  SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight - 28,
                      ),
                      child: Column(
                        children: <Widget>[
                          _HomeHeroStrip(
                            state: currentState,
                            driveDurationLabel: driveDurationLabel,
                            detectionArmed: detectionArmed,
                            faceInFrame: faceInFrame,
                          ),
                          const SizedBox(height: 16),
                          Center(
                            child: StatusCard(
                              key: ValueKey(currentState),
                              state: currentState,
                              confidence: confidence,
                              connectionStatus: connectionStatus,
                              isLoading: isLoading,
                              piStatusLabel: piStatusLabel,
                              detectionArmed: detectionArmed,
                              fatigue: fatigue,
                              signal: signal,
                              faceInFrame: faceInFrame,
                              faceLocked: faceLocked,
                              driveDurationLabel: driveDurationLabel,
                              sleepGapLabel: sleepGapLabel,
                              error: error,
                              width: cardWidth,
                              onOpenStats: () => _openStatsScreen(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _openStatsScreen(BuildContext context) {
    if (widget.onOpenStatsRequested != null) {
      widget.onOpenStatsRequested!.call();
      return;
    }
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 560),
        reverseTransitionDuration: const Duration(milliseconds: 420),
        pageBuilder: (context, animation, secondaryAnimation) {
          final curve = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );

          return FadeTransition(
            opacity: curve,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.06),
                end: Offset.zero,
              ).animate(curve),
              child: const StatsScreen(),
            ),
          );
        },
      ),
    );
  }

  void _triggerHapticOnStateChange(SleepState state) {
    if (_lastStateForHaptic == null) {
      _lastStateForHaptic = state;
      return;
    }

    if (_lastStateForHaptic == state) {
      return;
    }

    _lastStateForHaptic = state;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      HapticFeedback.selectionClick();
    });
  }

  void _showSleepAlertIfNeeded(
    SleepProvider provider,
    bool shouldShowSleepAlert,
    double confidence,
    String piStatusLabel,
    int? fatigue,
  ) {
    if (!shouldShowSleepAlert || _isAlertVisible) return;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _isAlertVisible) return;

      _isAlertVisible = true;

      await showCupertinoDialog<void>(
        context: context,
        builder: (context) {
          return CupertinoAlertDialog(
            title: const Text('Sleep Alert / Cảnh báo ngủ gật'),
            content: Text(
              'Status / Trạng thái: $piStatusLabel\n'
              'Confidence / Độ tin cậy: ${(confidence * 100).toStringAsFixed(0)}%'
              '${fatigue == null ? '' : '\nFatigue / Mệt mỏi: $fatigue'}',
            ),
            actions: <Widget>[
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK / Đã hiểu'),
              ),
            ],
          );
        },
      );

      if (!mounted) return;

      // 🔥 reset đúng thời điểm
      provider.acknowledgeSleepAlert();

      _isAlertVisible = false;
    });
  }

  void _showRestAlertIfNeeded(
    SleepProvider provider,
    bool shouldShowRestAlert,
    int recentSleepEvents2m,
    String sleepGapLabel,
  ) {
    if (!shouldShowRestAlert || _isRestAlertVisible) return;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _isRestAlertVisible) return;

      _isRestAlertVisible = true;

      await showCupertinoDialog<void>(
        context: context,
        builder: (context) {
          return CupertinoAlertDialog(
            title: const Text('Rest Needed / Cần nghỉ ngơi'),
            content: Text(
              'Detected $recentSleepEvents2m sleep events within 2 minutes.\n'
              'Khoảng cách gần nhất: $sleepGapLabel.\n'
              'Bạn cần nghỉ ngơi trước khi tiếp tục lái xe.',
            ),
            actions: <Widget>[
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK / Đã hiểu'),
              ),
            ],
          );
        },
      );

      if (!mounted) return;
      provider.acknowledgeRestAlert();
      _isRestAlertVisible = false;
    });
  }

  List<Color> _backgroundGradient(SleepState state) {
    switch (state) {
      case SleepState.normal:
        return const <Color>[
          Color(0xFF071220),
          Color(0xFF0F2240),
          Color(0xFF1A3058),
        ];
      case SleepState.sleepy:
        return const <Color>[
          Color(0xFF12101E),
          Color(0xFF2D2444),
          Color(0xFF5A3D38),
        ];
      case SleepState.sleep:
        return const <Color>[
          Color(0xFF14081C),
          Color(0xFF3A1430),
          Color(0xFF5E1A2C),
        ];
    }
  }

  Color _stateColor(SleepState state) {
    switch (state) {
      case SleepState.normal:
        return const Color(0xFF34D399);
      case SleepState.sleepy:
        return const Color(0xFFFBBF24);
      case SleepState.sleep:
        return const Color(0xFFF87171);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Ambient Glow Blob
// ─────────────────────────────────────────────────────────────────────────────
class _GlowBlob extends StatelessWidget {
  const _GlowBlob({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: <Color>[color, color.withValues(alpha: 0.0)],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hero Strip — top bar with app name, status pills
// ─────────────────────────────────────────────────────────────────────────────
class _HomeHeroStrip extends StatelessWidget {
  const _HomeHeroStrip({
    required this.state,
    required this.driveDurationLabel,
    required this.detectionArmed,
    required this.faceInFrame,
  });

  final SleepState state;
  final String driveDurationLabel;
  final bool detectionArmed;
  final bool faceInFrame;

  @override
  Widget build(BuildContext context) {
    final accent = switch (state) {
      SleepState.normal => const Color(0xFF34D399),
      SleepState.sleepy => const Color(0xFFFBBF24),
      SleepState.sleep => const Color(0xFFF87171),
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white.withValues(alpha: 0.06),
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
              // Animated accent dot
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: accent.withValues(alpha: 0.70),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Drowsy Monitor',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              const Spacer(),
              // Drive duration badge
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      CupertinoIcons.timer,
                      size: 13,
                      color: Colors.white.withValues(alpha: 0.55),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      driveDurationLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.80),
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        fontFeatures: <FontFeature>[
                          const FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Status pills
          Row(
            children: <Widget>[
              _StatusPill(
                label: detectionArmed ? 'System Ready' : 'Arming...',
                icon: detectionArmed
                    ? CupertinoIcons.checkmark_shield_fill
                    : CupertinoIcons.shield,
                tint: detectionArmed
                    ? const Color(0xFF34D399)
                    : const Color(0xFFFBBF24),
              ),
              const SizedBox(width: 8),
              _StatusPill(
                label: faceInFrame ? 'Face Detected' : 'No Face',
                icon: faceInFrame
                    ? CupertinoIcons.person_crop_circle_fill_badge_checkmark
                    : CupertinoIcons.person_crop_circle_badge_xmark,
                tint: faceInFrame
                    ? const Color(0xFF60A5FA)
                    : const Color(0xFFFB923C),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Status Pill — compact badge with icon
// ─────────────────────────────────────────────────────────────────────────────
class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.icon,
    required this.tint,
  });

  final String label;
  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: tint.withValues(alpha: 0.20),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: tint.withValues(alpha: 0.85)),
          const SizedBox(width: 6),
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
