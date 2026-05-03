class SleepModel {
  SleepModel({
    this.id,
    required this.state,
    required this.confidence,
    required this.time,
    this.runtimeMs,
    this.rawStatus,
    this.signal,
    this.fatigue,
    this.armed,
    this.faceLock,
    this.faceInFrame,
    this.eventId,
    this.topic,
  });

  final int? id;
  final SleepState state;
  final double confidence;
  final DateTime time;
  final int? runtimeMs;
  final String? rawStatus;
  final int? signal;
  final int? fatigue;
  final bool? armed;
  final bool? faceLock;
  final bool? faceInFrame;
  final String? eventId;
  final String? topic;

  factory SleepModel.fromJson(Map<String, dynamic> json) {
    return SleepModel(
      state: SleepStateX.fromRaw(json['state'] as String?),
      confidence: _parseConfidence(json['confidence']),
      time: _parseTimestamp(json['time']),
      runtimeMs: _parseInt(json['runtime_ms']),
      rawStatus: _parseRawStatus(json['raw_status'] ?? json['status']),
      signal: _parseInt(json['signal']),
      fatigue: _parseInt(json['fatigue']),
      armed: _parseBool(json['armed']),
      faceLock: _parseBool(json['face_lock']),
      faceInFrame: _parseBool(json['face_in_frame']),
      eventId: _parseString(json['event_id']),
      topic: _parseString(json['topic']),
    );
  }

  factory SleepModel.fromMap(Map<String, dynamic> map) {
    return SleepModel(
      id: map['id'] as int?,
      state: SleepStateX.fromRaw(map['state'] as String?),
      confidence: _parseConfidence(map['confidence']),
      time: _parseTimestamp(map['timestamp']),
      runtimeMs: _parseInt(map['runtime_ms']),
      rawStatus: _parseRawStatus(map['raw_status'] ?? map['status']),
      signal: _parseInt(map['signal']),
      fatigue: _parseInt(map['fatigue']),
      armed: _parseBool(map['armed']),
      faceLock: _parseBool(map['face_lock']),
      faceInFrame: _parseBool(map['face_in_frame']),
      eventId: _parseString(map['event_id']),
      topic: _parseString(map['topic']),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'state': state.rawValue,
      'confidence': confidence,
      'time': time.millisecondsSinceEpoch,
      if (runtimeMs != null) 'runtime_ms': runtimeMs,
      if (rawStatus != null) 'raw_status': rawStatus,
      if (signal != null) 'signal': signal,
      if (fatigue != null) 'fatigue': fatigue,
      if (armed != null) 'armed': armed,
      if (faceLock != null) 'face_lock': faceLock,
      if (faceInFrame != null) 'face_in_frame': faceInFrame,
      if (eventId != null) 'event_id': eventId,
      if (topic != null) 'topic': topic,
    };
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'state': state.rawValue,
      'confidence': confidence,
      'timestamp': time.millisecondsSinceEpoch,
      if (runtimeMs != null) 'runtime_ms': runtimeMs,
      if (rawStatus != null) 'raw_status': rawStatus,
      if (signal != null) 'signal': signal,
      if (fatigue != null) 'fatigue': fatigue,
      if (armed != null) 'armed': armed! ? 1 : 0,
      if (faceLock != null) 'face_lock': faceLock! ? 1 : 0,
      if (faceInFrame != null) 'face_in_frame': faceInFrame! ? 1 : 0,
      if (eventId != null) 'event_id': eventId,
      if (topic != null) 'topic': topic,
    };
  }

  SleepModel withMissingFrom(SleepModel? base) {
    if (base == null) {
      return this;
    }
    return SleepModel(
      id: id,
      state: state,
      confidence: confidence,
      time: time,
      runtimeMs: runtimeMs ?? base.runtimeMs,
      rawStatus: rawStatus ?? base.rawStatus,
      signal: signal ?? base.signal,
      fatigue: fatigue ?? base.fatigue,
      armed: armed ?? base.armed,
      faceLock: faceLock ?? base.faceLock,
      faceInFrame: faceInFrame ?? base.faceInFrame,
      eventId: eventId ?? base.eventId,
      topic: topic ?? base.topic,
    );
  }

  static double _parseConfidence(dynamic value) {
    final double parsed = switch (value) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s) ?? 0.0,
      _ => 0.0,
    };

    if (parsed.isNaN || parsed.isInfinite) {
      return 0.0;
    }

    if (parsed < 0) {
      return 0.0;
    }

    if (parsed > 1) {
      return 1.0;
    }

    return parsed;
  }

  static DateTime _parseTimestamp(dynamic value) {
    if (value is DateTime) {
      return value;
    }

    if (value is int) {
      return value > 9999999999
          ? DateTime.fromMillisecondsSinceEpoch(value)
          : DateTime.fromMillisecondsSinceEpoch(value * 1000);
    }

    if (value is double) {
      final intValue = value.toInt();
      return intValue > 9999999999
          ? DateTime.fromMillisecondsSinceEpoch(intValue)
          : DateTime.fromMillisecondsSinceEpoch(intValue * 1000);
    }

    if (value is String) {
      final parsedInt = int.tryParse(value);
      if (parsedInt != null) {
        return parsedInt > 9999999999
            ? DateTime.fromMillisecondsSinceEpoch(parsedInt)
            : DateTime.fromMillisecondsSinceEpoch(parsedInt * 1000);
      }

      final parsedDate = DateTime.tryParse(value);
      if (parsedDate != null) {
        return parsedDate;
      }
    }

    return DateTime.now();
  }

  static int? _parseInt(dynamic value) {
    return switch (value) {
      final int i => i,
      final num n => n.toInt(),
      final String s => int.tryParse(s),
      _ => null,
    };
  }

  static bool? _parseBool(dynamic value) {
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

  static String? _parseString(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return text;
  }

  static String? _parseRawStatus(dynamic value) {
    final text = _parseString(value);
    if (text == null) return null;
    return text.toUpperCase();
  }
}

enum SleepState { sleep, sleepy, normal }

extension SleepStateX on SleepState {
  String get rawValue {
    switch (this) {
      case SleepState.sleep:
        return 'sleep';
      case SleepState.sleepy:
        return 'sleepy';
      case SleepState.normal:
        return 'normal';
    }
  }

  String get label {
    switch (this) {
      case SleepState.sleep:
        return 'SLEEP';
      case SleepState.sleepy:
        return 'SLEEPY';
      case SleepState.normal:
        return 'NORMAL';
    }
  }

  double get chartValue {
    switch (this) {
      case SleepState.sleep:
        return 1.0;
      case SleepState.sleepy:
        return 0.5;
      case SleepState.normal:
        return 0.0;
    }
  }

  static bool isValidRaw(String? value) {
    final v = value?.trim().toLowerCase();
    return v == 'sleep' || v == 'sleepy' || v == 'normal';
  }

  static SleepState fromRaw(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'sleep':
        return SleepState.sleep;
      case 'sleepy':
        return SleepState.sleepy;
      case 'normal':
        return SleepState.normal;
      default:
        return SleepState.normal;
    }
  }
}
