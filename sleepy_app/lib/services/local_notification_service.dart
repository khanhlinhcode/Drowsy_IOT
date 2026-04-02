import 'dart:math';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class LocalNotificationService {
  LocalNotificationService._internal();

  static final LocalNotificationService instance =
      LocalNotificationService._internal();

  static const int _alertCooldownMs = 1200;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  String? _lastDedupKey;
  int _lastAlertAtMs = 0;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    const iOSInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      defaultPresentAlert: true,
      defaultPresentBadge: true,
      defaultPresentSound: true,
    );

    const init = InitializationSettings(iOS: iOSInit);
    await _plugin.initialize(init);

    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    _initialized = true;
  }

  Future<void> showSleepyAlert({
    required double confidence,
    int? eventTimestampMs,
    String? dedupKey,
  }) {
    return _showAlert(
      title: 'Drowsiness Warning',
      body:
          'Sleepy state detected (${(confidence * 100).clamp(0, 100).toStringAsFixed(0)}%). Please stay alert.',
      eventTimestampMs: eventTimestampMs,
      dedupKey: dedupKey,
      threadIdentifier: 'sleepy_alerts',
    );
  }

  Future<void> showSleepAlert({
    required double confidence,
    int? eventTimestampMs,
    String? dedupKey,
  }) {
    return _showAlert(
      title: 'Drowsiness Alert',
      body:
          'Sleep detected (${(confidence * 100).clamp(0, 100).toStringAsFixed(0)}% confidence). Please take action immediately.',
      eventTimestampMs: eventTimestampMs,
      dedupKey: dedupKey,
      threadIdentifier: 'sleep_alerts',
    );
  }

  Future<void> _showAlert({
    required String title,
    required String body,
    required String threadIdentifier,
    int? eventTimestampMs,
    String? dedupKey,
  }) async {
    await initialize();

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final eventMs = eventTimestampMs ?? nowMs;
    final eventKey = dedupKey ?? '$threadIdentifier-$eventMs';

    if (_lastDedupKey == eventKey) {
      return;
    }

    if ((nowMs - _lastAlertAtMs) < _alertCooldownMs) {
      return;
    }

    _lastDedupKey = eventKey;
    _lastAlertAtMs = nowMs;

    final details = NotificationDetails(
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        threadIdentifier: threadIdentifier,
      ),
    );

    final int notificationId = max(1, (eventMs ~/ 1000) & 0x7fffffff);

    await _plugin.show(notificationId, title, body, details, payload: eventKey);
  }
}
