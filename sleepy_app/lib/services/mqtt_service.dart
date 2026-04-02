import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart' as mqtt;
import 'package:mqtt_client/mqtt_server_client.dart';

import '../models/sleep_model.dart';

enum MqttFeedStatus { connecting, connected, reconnecting, disconnected, error }

class MqttConfig {
  const MqttConfig({
    required this.broker,
    required this.topic,
    this.port = 1883,
    this.clientId = 'sleepy-app-ios',
    this.keepAliveSeconds = 20,
    this.username,
    this.password,
    this.useTls = false,
    this.allowInsecureCertificates = false,
    this.qos = mqtt.MqttQos.atLeastOnce,
    this.enableDebugLogs = true,
  });

  final String broker;
  final int port;
  final String topic;
  final String clientId;
  final int keepAliveSeconds;
  final String? username;
  final String? password;
  final bool useTls;
  final bool allowInsecureCertificates;
  final mqtt.MqttQos qos;
  final bool enableDebugLogs;
}

class MqttService {
  MqttService({required this.config});

  final MqttConfig config;

  final StreamController<SleepModel> _messageController =
      StreamController<SleepModel>.broadcast();
  final StreamController<MqttFeedStatus> _statusController =
      StreamController<MqttFeedStatus>.broadcast();

  MqttServerClient? _client;
  StreamSubscription<List<mqtt.MqttReceivedMessage<mqtt.MqttMessage>>>?
  _updatesSubscription;
  Timer? _reconnectTimer;

  bool _isDisposed = false;
  bool _manualDisconnect = false;
  bool _isConnecting = false;
  int _reconnectAttempt = 0;

  Stream<SleepModel> get messages => _messageController.stream;
  Stream<MqttFeedStatus> get connectionStatus => _statusController.stream;

  Future<void> connect() async {
    if (_isDisposed) {
      return;
    }

    if (_isConnecting) {
      return;
    }

    final currentStatus = _client?.connectionStatus?.state;
    if (currentStatus == mqtt.MqttConnectionState.connected) {
      _emitStatus(MqttFeedStatus.connected);
      return;
    }

    _manualDisconnect = false;
    await _openConnection();
  }

  Future<void> disconnect() async {
    if (_isDisposed) {
      return;
    }

    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    await _updatesSubscription?.cancel();
    _updatesSubscription = null;

    _safeDisconnect(_client);
    _client = null;

    _emitStatus(MqttFeedStatus.disconnected);
  }

  Future<void> _openConnection() async {
    if (_isDisposed || _manualDisconnect) {
      return;
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    await _updatesSubscription?.cancel();
    _updatesSubscription = null;

    _isConnecting = true;
    _emitStatus(
      _reconnectAttempt > 0
          ? MqttFeedStatus.reconnecting
          : MqttFeedStatus.connecting,
    );

    final clientId =
        '${config.clientId}-${DateTime.now().millisecondsSinceEpoch}';

    final client =
        MqttServerClient.withPort(config.broker, clientId, config.port)
          ..keepAlivePeriod = config.keepAliveSeconds
          ..autoReconnect = false
          ..resubscribeOnAutoReconnect = false
          ..secure = config.useTls
          ..logging(on: false)
          ..onConnected = _onConnected
          ..onDisconnected = _onDisconnected
          ..onSubscribed = _onSubscribed
          ..onSubscribeFail = _onSubscribeFail
          ..pongCallback = _onPong
          ..onBadCertificate = (Object cert) {
            return config.allowInsecureCertificates;
          }
          ..connectionMessage = mqtt.MqttConnectMessage()
              .withClientIdentifier(clientId)
              .startClean()
              .withWillQos(config.qos);

    try {
      _debugLog('Connecting to ${config.broker}:${config.port}');
      final status = await client.connect(config.username, config.password);

      if (status?.state != mqtt.MqttConnectionState.connected) {
        _debugLog('Connect failed, state=${status?.state}');
        _emitStatus(MqttFeedStatus.error);
        _safeDisconnect(client);
        _scheduleReconnect();
        return;
      }

      _client = client;
      _reconnectAttempt = 0;
      _emitStatus(MqttFeedStatus.connected);

      client.subscribe(config.topic, config.qos);
      _debugLog('Subscribed to topic=${config.topic} qos=${config.qos.index}');

      _updatesSubscription = client.updates?.listen(
        _onUpdates,
        onError: _onUpdatesError,
        onDone: _onUpdatesDone,
      );
    } catch (error, stackTrace) {
      _emitMessageError(Exception('MQTT connect error: $error'), stackTrace);
      _emitStatus(MqttFeedStatus.error);
      _safeDisconnect(client);
      _scheduleReconnect();
    } finally {
      _isConnecting = false;
    }
  }

  void _onConnected() {
    _debugLog('Connected');
    _emitStatus(MqttFeedStatus.connected);
  }

  void _onDisconnected() {
    if (_manualDisconnect || _isDisposed) {
      _debugLog('Disconnected (manual/disposed)');
      _emitStatus(MqttFeedStatus.disconnected);
      return;
    }

    _debugLog('Disconnected unexpectedly');
    _emitStatus(MqttFeedStatus.disconnected);
    _scheduleReconnect();
  }

  void _onSubscribed(String topic) {
    _debugLog('Subscription acknowledged topic=$topic');
    if (topic == config.topic) {
      _emitStatus(MqttFeedStatus.connected);
    }
  }

  void _onSubscribeFail(String topic) {
    _debugLog('Subscription failed topic=$topic');
    if (topic == config.topic) {
      _emitStatus(MqttFeedStatus.error);
      _scheduleReconnect();
    }
  }

  void _onPong() {
    // Keep-alive callback.
  }

  void _onUpdates(List<mqtt.MqttReceivedMessage<mqtt.MqttMessage>> events) {
    for (final event in events) {
      if (_isDisposed || !event.topic.startsWith(config.topic)) {
        continue;
      }

      try {
        final payload = event.payload as mqtt.MqttPublishMessage;
        final payloadText = mqtt.MqttPublishPayload.bytesToStringAsString(
          payload.payload.message,
        );
        _debugLog('RAW MQTT: $payloadText');
        final model = _parsePayload(payloadText);
        if (model != null) {
          _emitMessage(model);
        } else {
          _debugLog('Ignored invalid payload="$payloadText"');
        }
      } catch (error, stackTrace) {
        _emitMessageError(
          Exception('MQTT payload decode error: $error'),
          stackTrace,
        );
      }
    }
  }

  // SleepModel? _parsePayload(String payloadText) {
  //   final payload = payloadText.trim();
  //   if (payload.isEmpty) {
  //     return null;
  //   }

  //   try {
  //     final numericValue = int.tryParse(payload);
  //     if (numericValue != null) {
  //       return _modelFromNumeric(numericValue);
  //     }

  //     if (!payload.startsWith('{')) {
  //       return null;
  //     }

  //     final decoded = jsonDecode(payload);
  //     if (decoded is! Map<String, dynamic>) {
  //       return null;
  //     }

  //     final state = _stateFromJson(decoded);
  //     if (state == null) {
  //       return null;
  //     }

  //     return SleepModel(
  //       state: state,
  //       time: _timestampFromJson(decoded),
  //       confidence: _confidenceFromJson(decoded) ?? 1.0,
  //     );

  //   } catch (_) {
  //     return null;
  //   }
  // }
  SleepModel? _parsePayload(String payloadText) {
    final payload = payloadText.trim();
    if (payload.isEmpty) return null;

    try {
      // 1. numeric
      final numericValue = int.tryParse(payload);
      if (numericValue != null) {
        return _modelFromNumeric(numericValue);
      }

      // 2. JSON
      if (payload.startsWith('{')) {
        final decoded = jsonDecode(payload);
        if (decoded is! Map<String, dynamic>) return null;

        final state = _stateFromJson(decoded);
        if (state == null) return null;

        return SleepModel(
          state: state,
          time: _timestampFromJson(decoded),
          confidence: _confidenceFromJson(decoded) ?? 1.0,
        );
      }

      // 3. TEXT (🔥 THÊM DÒNG NÀY)
      return _parseLegacyText(payload);
    } catch (e) {
      _debugLog('Parse error: $e');
      return null;
    }
  }

  SleepModel? _parseLegacyText(String payload) {
    try {
      final upper = payload.toUpperCase();

      // DEBUG (rất quan trọng)
      _debugLog('RAW TEXT MQTT: $upper');

      // final statusMatch = RegExp(r'STATUS:\s*([A-Z\s]+)').firstMatch(upper);
      final statusMatch = RegExp(
        r'STATUS\s*:\s*([A-Z\s]+)',
        caseSensitive: false,
      ).firstMatch(payload);
      final fatigueMatch = RegExp(r'FATIGUE:\s*(\d+)').firstMatch(upper);

      if (statusMatch == null) return null;

      final statusRaw = statusMatch.group(1)?.trim();

      SleepState? state;

      switch (statusRaw) {
        case 'MICROSLEEP':
          state = SleepState.sleep;
          break;

        case 'ATTENTIVE':
          state = SleepState.normal;
          break;

        case 'DISTRACTED':
        case 'HEAD TILT':
        case 'LOOKING DOWN':
        case 'LOOKING LEFT': 
        case 'TIRED': 
          state = SleepState.sleepy;
          break;

        case 'NO FACE': 
          state = SleepState.normal; 
          break;

        default:
          _debugLog('UNKNOWN STATUS: $statusRaw');
          return null;
      }

      double confidence = 1.0;

      if (fatigueMatch != null) {
        final fatigue = int.tryParse(fatigueMatch.group(1)!);
        if (fatigue != null) {
          confidence = fatigue > 1 ? fatigue / 100 : fatigue.toDouble();
        }
      }

      return SleepModel(
        state: state,
        time: DateTime.now().add(
          Duration(milliseconds: math.Random().nextInt(5)),
        ),
        confidence: confidence,
      );
    } catch (e) {
      _debugLog('Parse TEXT error: $e');
      return null;
    }
  }

  SleepModel? _modelFromNumeric(int value) {
    final state = _stateFromNumericCode(value);
    if (state == null) {
      return null;
    }

    return SleepModel(state: state, time: DateTime.now(), confidence: 1.0);
  }

  SleepState? _stateFromJson(Map<String, dynamic> jsonMap) {
    final stateRaw = jsonMap['state'];

    if (stateRaw is String && SleepStateX.isValidRaw(stateRaw)) {
      return SleepStateX.fromRaw(stateRaw);
    }

    if (stateRaw is num) {
      return _stateFromNumericCode(stateRaw.toInt());
    }

    if (stateRaw is String) {
      return _stateFromNumericCode(int.tryParse(stateRaw));
    }

    return null;
  }

  SleepState? _stateFromNumericCode(int? value) {
    if (value == null) {
      return null;
    }

    switch (value) {
      case 0:
      case 1:
        return SleepState.normal;
      case 2:
        return SleepState.sleepy;
      case 3:
        return SleepState.sleep;
      default:
        return null;
    }
  }

  double? _confidenceFromJson(Map<String, dynamic> jsonMap) {
    final raw = jsonMap['confidence'];
    final value = switch (raw) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s),
      _ => null,
    };

    if (value == null || value.isNaN || value.isInfinite) {
      return null;
    }

    return value.clamp(0.0, 1.0).toDouble();
  }

  DateTime _timestampFromJson(Map<String, dynamic> jsonMap) {
    final raw = jsonMap['time'];

    if (raw is int) {
      return raw > 9999999999
          ? DateTime.fromMillisecondsSinceEpoch(raw)
          : DateTime.fromMillisecondsSinceEpoch(raw * 1000);
    }

    if (raw is num) {
      final value = raw.toInt();
      return value > 9999999999
          ? DateTime.fromMillisecondsSinceEpoch(value)
          : DateTime.fromMillisecondsSinceEpoch(value * 1000);
    }

    if (raw is String) {
      final parsedInt = int.tryParse(raw);
      if (parsedInt != null) {
        return parsedInt > 9999999999
            ? DateTime.fromMillisecondsSinceEpoch(parsedInt)
            : DateTime.fromMillisecondsSinceEpoch(parsedInt * 1000);
      }

      final parsedDate = DateTime.tryParse(raw);
      if (parsedDate != null) {
        return parsedDate;
      }
    }

    return DateTime.now();
  }

  void _onUpdatesError(Object error, [StackTrace? stackTrace]) {
    _debugLog('Stream error: $error');
    _emitMessageError(Exception('MQTT stream error: $error'), stackTrace);
    _emitStatus(MqttFeedStatus.error);
    _scheduleReconnect();
  }

  void _onUpdatesDone() {
    if (_manualDisconnect || _isDisposed) {
      return;
    }

    _debugLog('Updates stream closed');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_isDisposed || _manualDisconnect || _isConnecting) {
      return;
    }

    if (_reconnectTimer?.isActive ?? false) {
      return;
    }

    _safeDisconnect(_client);
    _client = null;

    _reconnectAttempt += 1;
    final backoffPower = math.max(0, _reconnectAttempt - 1);
    final delaySeconds = math.min(30, 1 << math.min(backoffPower, 5));

    _debugLog('Reconnecting in ${delaySeconds}s (attempt=$_reconnectAttempt)');

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      unawaited(_openConnection());
    });
  }

  void _safeDisconnect(MqttServerClient? client) {
    try {
      client?.disconnect();
    } catch (_) {
      // Cleanup path.
    }
  }

  void _emitMessage(SleepModel model) {
    if (_isDisposed || _messageController.isClosed) {
      return;
    }
    _messageController.add(model);
  }

  void _emitMessageError(Object error, [StackTrace? stackTrace]) {
    if (_isDisposed || _messageController.isClosed) {
      return;
    }
    _messageController.addError(error, stackTrace);
  }

  void _emitStatus(MqttFeedStatus status) {
    if (_isDisposed || _statusController.isClosed) {
      return;
    }
    _statusController.add(status);
  }

  void _debugLog(String message) {
    if (!config.enableDebugLogs || !kDebugMode) {
      return;
    }
    debugPrint('[MQTT] $message');
  }

  Future<void> dispose() async {
    _isDisposed = true;
    _manualDisconnect = true;

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    await _updatesSubscription?.cancel();
    _updatesSubscription = null;

    _safeDisconnect(_client);
    _client = null;

    if (!_messageController.isClosed) {
      await _messageController.close();
    }

    if (!_statusController.isClosed) {
      await _statusController.close();
    }
  }
}
