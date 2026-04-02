import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../database/db_helper.dart';
import '../models/sleep_model.dart';
import '../services/firebase_service.dart';
import '../services/local_notification_service.dart';
import '../services/mqtt_service.dart';

enum _SampleSource { mqtt, cloud }

class SleepProvider extends ChangeNotifier with WidgetsBindingObserver {
  SleepProvider({
    required String userId,
    DbHelper? dbHelper,
    MqttService? mqttService,
    LocalNotificationService? notificationService,
    FirebaseService? firebaseService,
    FlutterTts? tts,
  }) : _userId = userId,
       _dbHelper = dbHelper ?? DbHelper.instance,
       _firebaseService = firebaseService ?? FirebaseService.instance,
       _notificationService =
           notificationService ?? LocalNotificationService.instance,
       _tts = tts ?? FlutterTts(),
       _mqttService =
           mqttService ??
           MqttService(
             config: MqttConfig(
               broker: defaultBroker,

               port: defaultPort,
               topic: _resolveTopic(userId),
               clientId: '$defaultClientId-$userId',
               username: defaultUsername.isEmpty ? null : defaultUsername,
               password: defaultPassword.isEmpty ? null : defaultPassword,
               useTls: defaultUseTls,
               allowInsecureCertificates: defaultAllowInsecureCertificates,
               enableDebugLogs: enableMqttDebugLogs,
             ),
           );

  static const String defaultBroker = String.fromEnvironment(
    'MQTT_BROKER',
    // defaultValue: '192.168.0.163',
    defaultValue: '172.20.10.2',
  );

  static const int defaultPort = int.fromEnvironment(
    'MQTT_PORT',
    defaultValue: 1883,
  );
  static const String defaultClientId = 'sleepy-ios-client';
  static const String defaultUsername = String.fromEnvironment(
    'MQTT_USERNAME',
    defaultValue: '',
  );
  static const String defaultPassword = String.fromEnvironment(
    'MQTT_PASSWORD',
    defaultValue: '',
  );
  static const bool defaultUseTls = bool.fromEnvironment(
    'MQTT_TLS',
    defaultValue: false,
  );
  static const bool defaultAllowInsecureCertificates = bool.fromEnvironment(
    'MQTT_TLS_ALLOW_INSECURE',
    defaultValue: false,
  );
  static const bool enableMqttDebugLogs = bool.fromEnvironment(
    'MQTT_DEBUG',
    defaultValue: false,
  );

  static const String _topicOverride = String.fromEnvironment(
    'MQTT_TOPIC',
    defaultValue: '',
  );
  // static const String _topicPattern = String.fromEnvironment(
  //   'MQTT_TOPIC_PATTERN',
  //   defaultValue: 'driver/{userId}/status',
  // );
  static const String _topicPattern = 'driver/status';
  static const bool _enableCloudPull = bool.fromEnvironment(
    'CLOUD_PULL_ENABLED',
    defaultValue: true,
  );

  static const int historyLimit = 1000;
  static const int _minAcceptedGapMs = 0;

  // static const int _stateHoldMs = 200;
  static const int _stateHoldMs = 0;
  // static const int _alertCooldownMs = 1500;
  static const int _alertCooldownMs = 1000;
  static const int _seenEventsCap = 5000;
  // static const int _notifyMinGapMs = 120;
  static const int _notifyMinGapMs = 0;

  static String _resolveTopic(String userId) {
    if (_topicOverride.trim().isNotEmpty) {
      return _topicOverride.trim();
    }
    return _topicPattern.replaceAll('{userId}', userId);
  }

  final String _userId;
  final DbHelper _dbHelper;
  final MqttService _mqttService;
  final FirebaseService _firebaseService;
  final LocalNotificationService _notificationService;
  final FlutterTts _tts;

  final List<SleepModel> _history = <SleepModel>[];
  final Set<String> _seenEventKeys = <String>{};
  final ListQueue<String> _seenEventQueue = ListQueue<String>();

  StreamSubscription<SleepModel>? _messageSubscription;
  StreamSubscription<SleepModel>? _cloudSubscription;
  StreamSubscription<MqttFeedStatus>? _statusSubscription;

  Timer? _notifyTimer;
  int _lastNotifyAtMs = 0;

  SleepModel? _current;
  SleepState? _stableState;

  SleepState? _pendingState;
  SleepModel? _pendingModel;
  int _pendingSinceMs = 0;

  SleepState? _lastAcceptedState;
  int _lastAcceptedAtMs = 0;

  String? _lastAlertSignature;
  int _lastAlertAtMs = 0;
  String? _lastSpokenSignature;

  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;

  MqttFeedStatus _connectionStatus = MqttFeedStatus.disconnected;
  bool _isLoading = true;
  bool _initialized = false;
  bool _isDisposed = false;
  bool _isSleepAlertPending = false;
  bool _isTtsReady = false;
  String? _error;

  int _totalSleepCount = 0;
  int _totalSleepyCount = 0;
  int _totalNormalCount = 0;

  int _latestLatencyMs = 0;
  double _averageLatencyMs = 0;
  int _lastMessageAtMs = 0;

  String get userId => _userId;
  String get subscribedTopic => _mqttService.config.topic;

  List<SleepModel> get history => List<SleepModel>.unmodifiable(_history);
  SleepModel? get current => _current;
  MqttFeedStatus get connectionStatus => _connectionStatus;

  bool get isLoading => _isLoading;
  bool get shouldShowSleepAlert => _isSleepAlertPending;
  String? get error => _error;

  bool get isConnected => _connectionStatus == MqttFeedStatus.connected;
  bool get isDisconnected =>
      _connectionStatus == MqttFeedStatus.disconnected ||
      _connectionStatus == MqttFeedStatus.error;

  int get totalSleepCount => _totalSleepCount;
  int get totalSleepyCount => _totalSleepyCount;
  int get totalNormalCount => _totalNormalCount;
  int get totalEvents => _history.length;

  int get latestLatencyMs => _latestLatencyMs;
  int get averageLatencyMs => _averageLatencyMs.round();

  String get connectionQuality {
    if (isDisconnected) {
      return 'lost';
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_lastMessageAtMs > 0 && (nowMs - _lastMessageAtMs) > 10000) {
      return 'lost';
    }

    if (averageLatencyMs <= 400) {
      return 'good';
    }

    return 'weak';
  }

  double get averageConfidence {
    if (_history.isEmpty) {
      return 0;
    }

    final sum = _history.fold<double>(0, (acc, item) => acc + item.confidence);
    return sum / _history.length;
  }

  double get fatiguePercentage {
    if (_history.isEmpty) {
      return 0;
    }

    final score = _totalSleepCount + (_totalSleepyCount * 0.5);
    return (score / _history.length) * 100;
  }

  Map<SleepState, int> get stateDistribution => <SleepState, int>{
    SleepState.normal: _totalNormalCount,
    SleepState.sleepy: _totalSleepyCount,
    SleepState.sleep: _totalSleepCount,
  };

  bool get _isForeground =>
      _appLifecycleState == AppLifecycleState.resumed ||
      _appLifecycleState == AppLifecycleState.inactive;

  Future<void> initialize() async {
    if (_initialized || _isDisposed) {
      return;
    }
    _initialized = true;

    WidgetsBinding.instance.addObserver(this);

    await _notificationService.initialize();
    await _initializeTts();
    await _loadHistory();

    _statusSubscription = _mqttService.connectionStatus.listen(
      _onConnectionStatusChanged,
    );

    _messageSubscription = _mqttService.messages.listen(
      _onMqttData,
      onError: (Object error) {
        _setError(error.toString());
      },
    );

    if (_enableCloudPull) {
      _startCloudPull();
    }

    await _mqttService.connect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;

    if (_isDisposed) {
      return;
    }

    if (state == AppLifecycleState.resumed && !isConnected) {
      unawaited(_mqttService.connect());
    }
  }

  void _onConnectionStatusChanged(MqttFeedStatus status) {
    if (_connectionStatus == status) {
      return;
    }

    _connectionStatus = status;
    _debugLog('MQTT status: $status');

    switch (status) {
      case MqttFeedStatus.connected:
        _error = null;
        break;
      case MqttFeedStatus.connecting:
      case MqttFeedStatus.reconnecting:
        break;
      case MqttFeedStatus.disconnected:
        _error = 'MQTT disconnected. Reconnecting...';
        break;
      case MqttFeedStatus.error:
        _error = 'MQTT connection error. Reconnecting...';
        break;
    }

    _notifySafely();
  }

  Future<void> _initializeTts() async {
    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.46);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      _isTtsReady = true;
    } catch (_) {
      _isTtsReady = false;
    }
  }

  Future<void> _loadHistory() async {
    _isLoading = true;
    _notifySafely(immediate: true);

    try {
      final savedRecords = await _dbHelper.getSleepHistory(limit: historyLimit);
      _history
        ..clear()
        ..addAll(savedRecords);

      _seenEventKeys.clear();
      _seenEventQueue.clear();
      for (final entry in _history) {
        _markEventSeen(_eventKey(entry));
      }

      if (_history.isNotEmpty) {
        _current = _history.last;
        _stableState = _current!.state;
        _lastAcceptedState = _current!.state;
      }

      _recalculateAggregates();
      _error = null;
    } catch (_) {
      _error = 'Unable to load local history from SQLite.';
    } finally {
      _isLoading = false;
      _notifySafely(immediate: true);
    }
  }

  void _startCloudPull() {
    _cloudSubscription?.cancel();
    _cloudSubscription = _firebaseService
        .streamRecordChanges(userId: _userId, limit: historyLimit)
        .listen(
          _onCloudData,
          onError: (_) {
            if (_error == null) {
              _setError('Cloud sync unavailable. Running in local-only mode.');
            }
          },
        );
  }

  void _onMqttData(SleepModel incoming) {
    _debugLog(
      'MQTT data state=${incoming.state.rawValue} '
      'time=${incoming.time.millisecondsSinceEpoch}',
    );

    _updateLatency(incoming);
    _processIncoming(incoming, source: _SampleSource.mqtt);
  }

  void _onCloudData(SleepModel incoming) {
    _processIncoming(incoming, source: _SampleSource.cloud);
  }

  void _processIncoming(SleepModel incoming, {required _SampleSource source}) {
    final key = _eventKey(incoming);
    if (_seenEventKeys.contains(key)) {
      return;
    }

    if (_isExactDuplicate(incoming, _current) ||
        _isExactDuplicate(incoming, _pendingModel)) {
      _markEventSeen(key);
      return;
    }

    if (source == _SampleSource.mqtt) {
      final receivedAtMs = DateTime.now().millisecondsSinceEpoch;
      if (!_shouldAcceptIncoming(incoming.state, receivedAtMs)) {
        return;
      }

      if (_stableState == null) {
        _stableState = incoming.state;
        _commitSample(incoming, source: source, previousState: _current?.state);
        return;
      }

      if (incoming.state == _stableState) {
        _clearPendingState();
        _commitSample(incoming, source: source, previousState: _current?.state);
        return;
      }

      if (_pendingState != incoming.state) {
        _pendingState = incoming.state;
        _pendingSinceMs = receivedAtMs;
        _pendingModel = incoming;
        return;
      }

      _pendingModel = incoming;
      if ((receivedAtMs - _pendingSinceMs) < _stateHoldMs) {
        return;
      }

      final previousStable = _stableState;
      _stableState = incoming.state;
      _clearPendingState();
      _commitSample(incoming, source: source, previousState: previousStable);
      return;
    }

    _commitSample(incoming, source: source, previousState: _current?.state);
  }

  bool _shouldAcceptIncoming(SleepState newState, int receivedAtMs) {
    final previousAcceptedState = _lastAcceptedState;
    final previousAcceptedAtMs = _lastAcceptedAtMs;

    if (previousAcceptedState == null) {
      _lastAcceptedState = newState;
      _lastAcceptedAtMs = receivedAtMs;
      return true;
    }

    if (newState != previousAcceptedState) {
      _lastAcceptedState = newState;
      _lastAcceptedAtMs = receivedAtMs;
      return true;
    }

    if ((receivedAtMs - previousAcceptedAtMs) >= _minAcceptedGapMs) {
      _lastAcceptedState = newState;
      _lastAcceptedAtMs = receivedAtMs;
      return true;
    }

    return false;
  }

  // void _commitSample(
  //   SleepModel sample, {
  //   required _SampleSource source,
  //   required SleepState? previousState,
  // }) {
  //   final key = _eventKey(sample);
  //   _markEventSeen(key);

  //   _insertIntoHistory(sample);

  //   final wasCurrent = _current;
  //   final shouldUpdateCurrent =
  //       wasCurrent == null ||
  //       sample.time.isAfter(wasCurrent.time) ||
  //       sample.time.millisecondsSinceEpoch ==
  //           wasCurrent.time.millisecondsSinceEpoch;

  //   if (shouldUpdateCurrent) {
  //     _current = sample;
  //     if (source == _SampleSource.mqtt) {
  //       _stableState = sample.state;
  //     }

  //     _handleAlerts(previousState ?? wasCurrent?.state, sample);
  //   }

  //   _recalculateAggregates();
  //   _notifySafely();

  //   unawaited(_persist(sample));

  //   if (source == _SampleSource.mqtt) {
  //     unawaited(_syncToCloud(sample));
  //   }
  // }
  void _commitSample(
    SleepModel sample, {
    required _SampleSource source,
    required SleepState? previousState,
  }) {
    final key = _eventKey(sample);
    _markEventSeen(key);

    _insertIntoHistory(sample);

    final wasCurrent = _current;
    final shouldUpdateCurrent =
        wasCurrent == null ||
        sample.time.isAfter(wasCurrent.time) ||
        sample.time.millisecondsSinceEpoch ==
            wasCurrent.time.millisecondsSinceEpoch;

    if (shouldUpdateCurrent) {
      _current = sample;

      if (source == _SampleSource.mqtt) {
        _stableState = sample.state;
      }

      _handleAlerts(previousState ?? wasCurrent?.state, sample);
    }

    _recalculateAggregates();

    // giữ cái này cho background update
    _notifySafely();

    unawaited(_persist(sample));

    if (source == _SampleSource.mqtt) {
      unawaited(_syncToCloud(sample));
    }
  }

  void _insertIntoHistory(SleepModel sample) {
    if (_history.isEmpty || !sample.time.isBefore(_history.last.time)) {
      _history.add(sample);
    } else {
      final index = _history.indexWhere(
        (entry) => entry.time.isAfter(sample.time),
      );
      if (index < 0) {
        _history.add(sample);
      } else {
        _history.insert(index, sample);
      }
    }

    if (_history.length > historyLimit) {
      _history.removeRange(0, _history.length - historyLimit);
    }
  }

  Future<void> _persist(SleepModel entry) async {
    try {
      await _dbHelper.insertSleepRecord(entry);
    } catch (_) {
      _setError('State updated but failed to persist into SQLite.');
    }
  }

  Future<void> _syncToCloud(SleepModel entry) async {
    try {
      await _firebaseService.saveSleepRecord(userId: _userId, record: entry);
    } catch (_) {
      // Keep app real-time even when cloud write fails.
    }
  }

  void _handleAlerts(SleepState? previousState, SleepModel entry) {
    if (entry.state != SleepState.sleep) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;

    if ((nowMs - _lastAlertAtMs) < _alertCooldownMs) return;

    _lastAlertAtMs = nowMs;

    _debugLog("🔥 ALERT TRIGGERED");

    _isSleepAlertPending = true;

    _notifySafely(immediate: true);

    if (_isForeground) {
      HapticFeedback.heavyImpact();
    } else {
      _notificationService.showSleepAlert(
        confidence: entry.confidence,
        eventTimestampMs: entry.time.millisecondsSinceEpoch,
        dedupKey: '$nowMs',
      );
    }

    _speakSleepWarning('$nowMs');
  }

  Future<void> _speakSleepWarning(String signature) async {
    if (!_isTtsReady || !_isForeground) {
      return;
    }

    if (_lastSpokenSignature == signature) {
      return;
    }

    _lastSpokenSignature = signature;

    try {
      await _tts.stop();
      await _tts.speak(
        'Warning. Sleep detected. Please pull over and take a break.',
      );
    } catch (_) {
      // Ignore TTS failures.
    }
  }

  void _updateLatency(SleepModel incoming) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final eventMs = incoming.time.millisecondsSinceEpoch;

    _latestLatencyMs = math.max(0, nowMs - eventMs);
    _lastMessageAtMs = nowMs;

    if (_averageLatencyMs == 0) {
      _averageLatencyMs = _latestLatencyMs.toDouble();
      return;
    }

    _averageLatencyMs = (_averageLatencyMs * 0.85) + (_latestLatencyMs * 0.15);
  }

  void _recalculateAggregates() {
    var sleep = 0;
    var sleepy = 0;
    var normal = 0;

    for (final item in _history) {
      switch (item.state) {
        case SleepState.sleep:
          sleep += 1;
          break;
        case SleepState.sleepy:
          sleepy += 1;
          break;
        case SleepState.normal:
          normal += 1;
          break;
      }
    }

    _totalSleepCount = sleep;
    _totalSleepyCount = sleepy;
    _totalNormalCount = normal;
  }

  bool _isExactDuplicate(SleepModel a, SleepModel? b) {
    if (b == null) {
      return false;
    }

    return a.state == b.state &&
        a.time.millisecondsSinceEpoch == b.time.millisecondsSinceEpoch;
  }

  String _eventKey(SleepModel record) {
    return '${record.state.rawValue}-${record.time.millisecondsSinceEpoch}';
  }

  void _markEventSeen(String key) {
    if (!_seenEventKeys.add(key)) {
      return;
    }

    _seenEventQueue.addLast(key);
    while (_seenEventQueue.length > _seenEventsCap) {
      final oldest = _seenEventQueue.removeFirst();
      _seenEventKeys.remove(oldest);
    }
  }

  void _clearPendingState() {
    _pendingState = null;
    _pendingModel = null;
    _pendingSinceMs = 0;
  }

  void _notifySafely({bool immediate = false}) {
    if (_isDisposed) {
      return;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (immediate || (nowMs - _lastNotifyAtMs) >= _notifyMinGapMs) {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      _lastNotifyAtMs = nowMs;
      notifyListeners();
      return;
    }

    final waitMs = _notifyMinGapMs - (nowMs - _lastNotifyAtMs);
    _notifyTimer?.cancel();
    _notifyTimer = Timer(Duration(milliseconds: waitMs), () {
      if (_isDisposed) {
        return;
      }
      _lastNotifyAtMs = DateTime.now().millisecondsSinceEpoch;
      notifyListeners();
    });
  }

  void acknowledgeSleepAlert() {
    if (!_isSleepAlertPending) {
      return;
    }

    _isSleepAlertPending = false;
    _notifySafely(immediate: true);
  }

  void clearError() {
    if (_error == null) {
      return;
    }

    _error = null;
    _notifySafely(immediate: true);
  }

  void _setError(String message) {
    if (_error == message) {
      return;
    }

    _error = message;
    _debugLog('Provider error: $message');
    _notifySafely();
  }

  void _debugLog(String message) {
    if (!kDebugMode) {
      return;
    }
    debugPrint('[SleepProvider] $message');
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);

    _notifyTimer?.cancel();
    _notifyTimer = null;

    _messageSubscription?.cancel();
    _statusSubscription?.cancel();
    _cloudSubscription?.cancel();

    unawaited(_mqttService.dispose());
    unawaited(_tts.stop());
    super.dispose();
  }
}
