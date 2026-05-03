import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/sleep_model.dart';

class DbHelper {
  DbHelper._internal();

  static final DbHelper instance = DbHelper._internal();

  static const String _databaseName = 'sleep_monitor.db';
  static const int _databaseVersion = 4;
  static const String _tableName = 'sleep_records';
  static const int maxRows = 2000;

  Database? _database;

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = p.join(await getDatabasesPath(), _databaseName);

    return openDatabase(
      dbPath,
      version: _databaseVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            state TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0.0,
            timestamp INTEGER NOT NULL,
            runtime_ms INTEGER,
            raw_status TEXT,
            signal INTEGER,
            fatigue INTEGER,
            armed INTEGER,
            face_lock INTEGER,
            face_in_frame INTEGER,
            event_id TEXT,
            topic TEXT
          )
        ''');

        await _ensureIndexes(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE $_tableName ADD COLUMN confidence REAL NOT NULL DEFAULT 0.0',
          );
        }
        if (oldVersion < 3) {
          await _ensureSchema(db);
        }
        if (oldVersion < 4) {
          await _ensureSchema(db);
        }
      },
      onOpen: (db) async {
        await _ensureSchema(db);
        await _ensureIndexes(db);
      },
    );
  }

  Future<void> _ensureIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sleep_records_timestamp ON $_tableName(timestamp)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sleep_records_event_id ON $_tableName(event_id)',
    );
  }

  Future<void> _ensureSchema(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info($_tableName)');
    final names = <String>{
      for (final row in columns)
        (row['name']?.toString() ?? '').trim().toLowerCase(),
    };

    Future<void> addIfMissing(String columnSql, String columnName) async {
      if (names.contains(columnName.toLowerCase())) {
        return;
      }
      await db.execute('ALTER TABLE $_tableName ADD COLUMN $columnSql');
      names.add(columnName.toLowerCase());
    }

    await addIfMissing('confidence REAL NOT NULL DEFAULT 0.0', 'confidence');
    await addIfMissing('runtime_ms INTEGER', 'runtime_ms');
    await addIfMissing('raw_status TEXT', 'raw_status');
    await addIfMissing('signal INTEGER', 'signal');
    await addIfMissing('fatigue INTEGER', 'fatigue');
    await addIfMissing('armed INTEGER', 'armed');
    await addIfMissing('face_lock INTEGER', 'face_lock');
    await addIfMissing('face_in_frame INTEGER', 'face_in_frame');
    await addIfMissing('event_id TEXT', 'event_id');
    await addIfMissing('topic TEXT', 'topic');
  }

  Future<void> insertSleepRecord(SleepModel entry) async {
    final db = await database;

    await db.transaction((txn) async {
      await txn.insert(
        _tableName,
        entry.toMap()..remove('id'),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );

      // Keep local storage bounded for predictable query time and app size.
      await txn.execute('''
        DELETE FROM $_tableName
        WHERE id NOT IN (
          SELECT id FROM $_tableName
          ORDER BY id DESC
          LIMIT $maxRows
        )
      ''');
    });
  }

  Future<List<SleepModel>> getSleepHistory({int? limit}) async {
    final db = await database;
    final maps = await db.query(
      _tableName,
      orderBy: 'timestamp ASC',
      limit: limit,
    );

    return maps.map(SleepModel.fromMap).toList(growable: false);
  }

  Future<int> getTotalSleepCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM $_tableName WHERE state = ?',
      [SleepState.sleep.rawValue],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
