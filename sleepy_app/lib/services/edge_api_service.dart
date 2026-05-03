import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/sleep_model.dart';

class EdgeApiConfig {
  const EdgeApiConfig({
    required this.baseUrl,
    required this.deviceId,
    this.apiToken,
    this.pollIntervalMs = 1000,
    this.timeoutSeconds = 4,
    this.enableDebugLogs = true,
  });

  final String baseUrl;
  final String deviceId;
  final String? apiToken;
  final int pollIntervalMs;
  final int timeoutSeconds;
  final bool enableDebugLogs;
}

class EdgeApiService {
  EdgeApiService({required this.config});

  final EdgeApiConfig config;

  final StreamController<SleepModel> _messageController =
      StreamController<SleepModel>.broadcast();

  Timer? _pollTimer;
  bool _isDisposed = false;
  bool _isPolling = false;
  int _lastTimestampMs = 0;
  String _lastEventId = '';

  Stream<SleepModel> get stream => _messageController.stream;

  Future<void> start() async {
    if (_isDisposed || config.baseUrl.trim().isEmpty) {
      return;
    }
    await _pollLatest();
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      Duration(milliseconds: math.max(300, config.pollIntervalMs)),
      (_) {
        unawaited(_pollLatest());
      },
    );
  }

  Future<void> _pollLatest() async {
    if (_isDisposed || _isPolling) {
      return;
    }
    _isPolling = true;
    try {
      final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final devicePath = Uri.encodeComponent(config.deviceId);
      final uri = Uri.parse('$base/v1/devices/$devicePath/latest');
      final headers = <String, String>{'Accept': 'application/json'};
      final token = (config.apiToken ?? '').trim();
      if (token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      final resp = await http
          .get(uri, headers: headers)
          .timeout(Duration(seconds: math.max(1, config.timeoutSeconds)));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        _debug('HTTP ${resp.statusCode} on $uri');
        return;
      }

      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) {
        _debug('unexpected payload type from $uri');
        return;
      }

      final dynamic dataRaw = decoded['data'];
      if (dataRaw is! Map<String, dynamic>) {
        _debug('no data for device=${config.deviceId} from $uri');
        return;
      }

      final model = _mapLatestToModel(dataRaw);
      if (model == null) {
        _debug(
          'unable to map payload to SleepModel for device=${config.deviceId}',
        );
        return;
      }

      final eventId = model.eventId ?? '';
      final tsMs = model.time.millisecondsSinceEpoch;
      if (eventId.isNotEmpty &&
          eventId == _lastEventId &&
          tsMs == _lastTimestampMs) {
        return;
      }
      if (eventId.isEmpty && tsMs == _lastTimestampMs) {
        return;
      }

      _lastEventId = eventId;
      _lastTimestampMs = tsMs;
      if (!_messageController.isClosed) {
        _messageController.add(model);
      }
    } catch (e) {
      _debug('poll error: $e');
    } finally {
      _isPolling = false;
    }
  }

  SleepModel? _mapLatestToModel(Map<String, dynamic> jsonMap) {
    final rawStatus = (jsonMap['status_raw'] ?? jsonMap['status'] ?? '')
        .toString()
        .trim();
    final state = _stateFrom(rawStatus, jsonMap['signal']);
    if (state == null) {
      return null;
    }

    final tsMs = _toInt(
      jsonMap['timestamp_ms'] ?? jsonMap['epoch_ms'] ?? jsonMap['ts_ms'],
    );
    final runtimeMs = _toInt(jsonMap['runtime_ms'] ?? jsonMap['ts_ms']);
    final eventTime = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(tsMs)
        : DateTime.now();
    final fatigue = _toInt(jsonMap['fatigue']);
    final confidence = ((fatigue ?? 0) / 100.0).clamp(0.0, 1.0).toDouble();
    final faceInFrame =
        _toBool(jsonMap['face_in_frame']) ??
        (rawStatus.toUpperCase() != 'NO FACE' &&
            rawStatus.toUpperCase() != 'NO_FACE');

    return SleepModel(
      state: state,
      confidence: confidence,
      time: eventTime,
      runtimeMs: runtimeMs,
      rawStatus: rawStatus.isEmpty ? null : rawStatus.toUpperCase(),
      signal: _toInt(jsonMap['signal']),
      fatigue: fatigue,
      armed: _toBool(jsonMap['armed']),
      faceLock: _toBool(jsonMap['face_lock']),
      faceInFrame: faceInFrame,
      eventId: _toStr(jsonMap['event_id']),
      topic: 'edge-api/latest',
    );
  }

  SleepState? _stateFrom(String rawStatus, dynamic signalRaw) {
    final signal = _toInt(signalRaw);
    if (signal != null) {
      if (signal >= 3) return SleepState.sleep;
      if (signal >= 1) return SleepState.sleepy;
      return SleepState.normal;
    }

    final s = rawStatus.toUpperCase();
    if (s.isEmpty) return null;
    if (s == 'MICROSLEEP' || s == 'DROWSY' || s == 'SLEEP') {
      return SleepState.sleep;
    }
    if (s == 'SLEEPY' ||
        s == 'TIRED' ||
        s == 'VERY TIRED' ||
        s == 'DISTRACTED' ||
        s == 'HEAD DOWN' ||
        s == 'LOOKING DOWN' ||
        s == 'LOOKING LEFT' ||
        s == 'LOOKING RIGHT' ||
        s == 'HEAD TILT') {
      return SleepState.sleepy;
    }
    return SleepState.normal;
  }

  int? _toInt(dynamic value) {
    return switch (value) {
      final int i => i,
      final num n => n.toInt(),
      final String s => int.tryParse(s.trim()),
      _ => null,
    };
  }

  bool? _toBool(dynamic value) {
    return switch (value) {
      final bool b => b,
      final num n => n != 0,
      final String s =>
        s.trim().toLowerCase() == 'true'
            ? true
            : (s.trim() == '1'
                  ? true
                  : (s.trim().toLowerCase() == 'false' || s.trim() == '0'
                        ? false
                        : null)),
      _ => null,
    };
  }

  String? _toStr(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return text;
  }

  void _debug(String message) {
    if (!config.enableDebugLogs || !kDebugMode) {
      return;
    }
    debugPrint('[EDGE_API] $message');
  }

  Future<void> dispose() async {
    _isDisposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!_messageController.isClosed) {
      await _messageController.close();
    }
  }
}
