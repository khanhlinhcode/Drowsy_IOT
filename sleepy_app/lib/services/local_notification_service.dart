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
      title: 'Drowsiness Warning / Cảnh báo buồn ngủ',
      body:
          'Sleepy state detected (${(confidence * 100).clamp(0, 100).toStringAsFixed(0)}%). Please stay alert. / Phát hiện buồn ngủ, vui lòng tập trung lái xe.',
      eventTimestampMs: eventTimestampMs,
      dedupKey: dedupKey,
      threadIdentifier: 'sleepy_alerts',
    );
  }

  Future<void> showSleepAlert({
    required double confidence,
    String? statusLabel,
    int? fatigue,
    int? eventTimestampMs,
    String? dedupKey,
  }) {
    final statusText = (statusLabel == null || statusLabel.trim().isEmpty)
        ? ''
        : ' Status/Trạng thái: ${statusLabel.trim().toUpperCase()}.';
    final fatigueText = fatigue == null
        ? ''
        : ' Fatigue/Mệt mỏi: ${fatigue.clamp(0, 100)}.';
    return _showAlert(
      title: 'Drowsiness Alert / Cảnh báo ngủ gật',
      body:
          'Sleep detected (${(confidence * 100).clamp(0, 100).toStringAsFixed(0)}% confidence).$statusText$fatigueText Please take action immediately. / Phát hiện ngủ gật, hãy dừng xe an toàn ngay.',
      eventTimestampMs: eventTimestampMs,
      dedupKey: dedupKey,
      threadIdentifier: 'sleep_alerts',
    );
  }

  Future<void> showRestBreakAlert({
    required int recentCount,
    required int windowMs,
    int? eventTimestampMs,
    String? dedupKey,
  }) {
    final windowMin = (windowMs / 60000).toStringAsFixed(0);
    return _showAlert(
      title: 'Rest Recommendation / Khuyến nghị nghỉ ngơi',
      body:
          'Detected $recentCount drowsy events within $windowMin minutes. Please stop and rest. / Phát hiện nhiều lần ngủ gật trong $windowMin phút, bạn nên dừng xe và nghỉ ngơi ngay.',
      eventTimestampMs: eventTimestampMs,
      dedupKey: dedupKey,
      threadIdentifier: 'rest_recommendation_alerts',
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
