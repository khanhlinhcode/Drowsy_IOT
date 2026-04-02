import 'package:flutter_test/flutter_test.dart';
import 'package:sleepy_app/models/sleep_model.dart';

void main() {
  test('SleepModel parses MQTT payload with confidence', () {
    final now = DateTime.now().millisecondsSinceEpoch;

    final model = SleepModel.fromJson(<String, dynamic>{
      'state': 'sleepy',
      'confidence': 0.82,
      'time': now,
    });

    expect(model.state, SleepState.sleepy);
    expect(model.confidence, 0.82);
    expect(model.time.millisecondsSinceEpoch, now);
  });

  test('Confidence is clamped into [0, 1]', () {
    final modelLow = SleepModel.fromJson(<String, dynamic>{
      'state': 'normal',
      'confidence': -3,
      'time': 1700000000000,
    });
    final modelHigh = SleepModel.fromJson(<String, dynamic>{
      'state': 'sleep',
      'confidence': 3,
      'time': 1700000000000,
    });

    expect(modelLow.confidence, 0);
    expect(modelHigh.confidence, 1);
  });
}
