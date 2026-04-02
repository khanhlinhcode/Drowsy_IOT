import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/sleep_model.dart';

class FirebaseService {
  FirebaseService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  static final FirebaseService instance = FirebaseService();

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _recordsRef(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('sleep_records');
  }

  Future<void> saveSleepRecord({
    required String userId,
    required SleepModel record,
    String source = 'mobile',
  }) async {
    await _recordsRef(userId).add(<String, dynamic>{
      'state': record.state.rawValue,
      'time': record.time.millisecondsSinceEpoch,
      'confidence': record.confidence,
      'source': source,
      'synced_at': FieldValue.serverTimestamp(),
    });
  }

  Stream<SleepModel> streamRecordChanges({
    required String userId,
    int limit = 500,
  }) async* {
    final query = _recordsRef(
      userId,
    ).orderBy('time', descending: true).limit(limit);

    await for (final snapshot in query.snapshots()) {
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.removed) {
          continue;
        }

        final model = _parseRecord(change.doc.data());
        if (model != null) {
          yield model;
        }
      }
    }
  }

  SleepModel? _parseRecord(Map<String, dynamic>? data) {
    if (data == null) {
      return null;
    }

    final rawState = data['state'];
    if (rawState is! String || !SleepStateX.isValidRaw(rawState)) {
      return null;
    }

    final rawTime = data['time'];
    final int? timestampMs = switch (rawTime) {
      final int t => t,
      final num t => t.toInt(),
      final Timestamp t => t.millisecondsSinceEpoch,
      final String t => int.tryParse(t),
      _ => null,
    };

    if (timestampMs == null || timestampMs <= 0) {
      return null;
    }

    final rawConfidence = data['confidence'];
    final confidence = switch (rawConfidence) {
      final num c => c.toDouble(),
      final String s => double.tryParse(s) ?? 1.0,
      _ => 1.0,
    };

    return SleepModel(
      state: SleepStateX.fromRaw(rawState),
      time: DateTime.fromMillisecondsSinceEpoch(timestampMs),
      confidence: confidence.clamp(0.0, 1.0),
    );
  }
}
