import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/sleep_model.dart';

class DbHelper {
  DbHelper._internal();

  static final DbHelper instance = DbHelper._internal();

  static const String _databaseName = 'sleep_monitor.db';
  static const int _databaseVersion = 2;
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
            confidence REAL NOT NULL,
            timestamp INTEGER NOT NULL
          )
        ''');

        await db.execute(
          'CREATE INDEX idx_sleep_records_timestamp ON $_tableName(timestamp)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE $_tableName ADD COLUMN confidence REAL NOT NULL DEFAULT 0.0',
          );
        }
      },
    );
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
