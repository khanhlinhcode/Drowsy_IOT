class SleepModel {
  SleepModel({
    this.id,
    required this.state,
    required this.confidence,
    required this.time,
  });

  final int? id;
  final SleepState state;
  final double confidence;
  final DateTime time;

  factory SleepModel.fromJson(Map<String, dynamic> json) {
    return SleepModel(
      state: SleepStateX.fromRaw(json['state'] as String?),
      confidence: _parseConfidence(json['confidence']),
      time: _parseTimestamp(json['time']),
    );
  }

  factory SleepModel.fromMap(Map<String, dynamic> map) {
    return SleepModel(
      id: map['id'] as int?,
      state: SleepStateX.fromRaw(map['state'] as String?),
      confidence: _parseConfidence(map['confidence']),
      time: _parseTimestamp(map['timestamp']),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'state': state.rawValue,
      'confidence': confidence,
      'time': time.millisecondsSinceEpoch,
    };
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'state': state.rawValue,
      'confidence': confidence,
      'timestamp': time.millisecondsSinceEpoch,
    };
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
