import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'analytics_screen.dart';
import 'home_screen.dart';
import 'stats_screen.dart';

class MainTabsScreen extends StatefulWidget {
  const MainTabsScreen({super.key});

  @override
  State<MainTabsScreen> createState() => _MainTabsScreenState();
}

class _MainTabsScreenState extends State<MainTabsScreen> {
  int _currentIndex = 0;

  void _setTab(int index) {
    if (_currentIndex == index) {
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomeScreen(onOpenStatsRequested: () => _setTab(1)),
      const StatsScreen(showBackButton: false),
      const AnalyticsScreen(showBackButton: false),
    ];
    final tabs = <_TabMeta>[
      const _TabMeta(
        icon: CupertinoIcons.house_fill,
        inactiveIcon: CupertinoIcons.house,
        label: 'Home',
      ),
      const _TabMeta(
        icon: CupertinoIcons.chart_bar_alt_fill,
        inactiveIcon: CupertinoIcons.chart_bar,
        label: 'Stats',
      ),
      const _TabMeta(
        icon: CupertinoIcons.chart_pie_fill,
        inactiveIcon: CupertinoIcons.chart_pie,
        label: 'Analytics',
      ),
    ];

    return Scaffold(
      extendBody: true,
      body: IndexedStack(index: _currentIndex, children: pages),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: _TabBar(
            tabs: tabs,
            currentIndex: _currentIndex,
            onTap: _setTab,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab Bar — frosted glass iOS-style
// ─────────────────────────────────────────────────────────────────────────────
class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tabs,
    required this.currentIndex,
    required this.onTap,
  });

  final List<_TabMeta> tabs;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          height: 68,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                const Color(0xFF141E33).withValues(alpha: 0.92),
                const Color(0xFF0C1424).withValues(alpha: 0.95),
              ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.10),
              width: 0.5,
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.30),
                blurRadius: 28,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: <Widget>[
              for (int i = 0; i < tabs.length; i++)
                _TabItem(
                  icon: tabs[i].icon,
                  inactiveIcon: tabs[i].inactiveIcon,
                  label: tabs[i].label,
                  active: currentIndex == i,
                  onTap: () => onTap(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab Item — individual tab with active indicator
// ─────────────────────────────────────────────────────────────────────────────
class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.icon,
    required this.inactiveIcon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final IconData inactiveIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tint = active ? const Color(0xFF60A5FA) : Colors.white.withValues(alpha: 0.40);

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            // Active indicator dot
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: active ? 4 : 0,
              height: active ? 4 : 0,
              margin: const EdgeInsets.only(bottom: 5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? const Color(0xFF60A5FA) : Colors.transparent,
                boxShadow: active
                    ? <BoxShadow>[
                        BoxShadow(
                          color: const Color(0xFF60A5FA).withValues(alpha: 0.60),
                          blurRadius: 6,
                        ),
                      ]
                    : null,
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(
                active ? icon : inactiveIcon,
                key: ValueKey<bool>(active),
                color: tint,
                size: 22,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: tint,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                fontSize: 11,
                letterSpacing: 0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabMeta {
  const _TabMeta({
    required this.icon,
    required this.inactiveIcon,
    required this.label,
  });

  final IconData icon;
  final IconData inactiveIcon;
  final String label;
}
