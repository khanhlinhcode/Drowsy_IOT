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
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isAlertVisible = false;
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

    final currentState = current?.state ?? SleepState.normal;
    final confidence = current?.confidence ?? 0;
    final provider = context.read<SleepProvider>();
    _triggerHapticOnStateChange(currentState);
    _showSleepAlertIfNeeded(provider, shouldShowSleepAlert, confidence);

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
              final cardWidth = math.min(constraints.maxWidth - 24, 440.0);

              return Stack(
                children: <Widget>[
                  Positioned(
                    top: -120,
                    left: -96,
                    child: _GlowBlob(
                      color: Colors.white.withValues(alpha: 0.16),
                      size: 290,
                    ),
                  ),
                  Positioned(
                    top: constraints.maxHeight * 0.18,
                    right: -90,
                    child: _GlowBlob(
                      color: _stateColor(currentState).withValues(alpha: 0.18),
                      size: 260,
                    ),
                  ),
                  Positioned(
                    bottom: -130,
                    left: -70,
                    child: _GlowBlob(
                      color: const Color(0xFF9F7AEA).withValues(alpha: 0.16),
                      size: 300,
                    ),
                  ),
                  SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight - 28,
                      ),
                      child: Center(
                        child: StatusCard(
                          key: ValueKey(currentState),
                          state: currentState,
                          confidence: confidence,
                          connectionStatus: connectionStatus,
                          isLoading: isLoading,
                          error: error,
                          width: cardWidth,
                          onOpenStats: () => _openStatsScreen(context),
                        ),
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
  ) {
    if (!shouldShowSleepAlert || _isAlertVisible) return;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _isAlertVisible) return;

      _isAlertVisible = true;

      await showCupertinoDialog<void>(
        context: context,
        builder: (context) {
          return CupertinoAlertDialog(
            title: const Text('Sleep Alert'),
            content: Text(
              'Sleep detected (${(confidence * 100).toStringAsFixed(0)}%)',
            ),
            actions: <Widget>[
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
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

  List<Color> _backgroundGradient(SleepState state) {
    switch (state) {
      case SleepState.normal:
        return const <Color>[
          Color(0xFF081326),
          Color(0xFF142A52),
          Color(0xFF263A70),
        ];
      case SleepState.sleepy:
        return const <Color>[
          Color(0xFF15142D),
          Color(0xFF3D3058),
          Color(0xFF714D42),
        ];
      case SleepState.sleep:
        return const <Color>[
          Color(0xFF160C24),
          Color(0xFF42193A),
          Color(0xFF742235),
        ];
    }
  }

  Color _stateColor(SleepState state) {
    switch (state) {
      case SleepState.normal:
        return const Color(0xFF36E18A);
      case SleepState.sleepy:
        return const Color(0xFFFFBC42);
      case SleepState.sleep:
        return const Color(0xFFFF5A71);
    }
  }
}

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
          colors: <Color>[color, color.withValues(alpha: 0.01)],
        ),
      ),
    );
  }
}
