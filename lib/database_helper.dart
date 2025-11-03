// lib/database_helper.dart

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'models.dart';
import 'dart:convert';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('time_entries.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future _createDB(Database db, int version) async {
    // Time entries table
    await db.execute('''
    CREATE TABLE time_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      client_name TEXT NOT NULL,
      project_name TEXT NOT NULL,
      start_time TEXT NOT NULL,
      end_time TEXT,
      notes TEXT,
      is_exported INTEGER DEFAULT 0
    )
  ''');

    // Clients/Projects table
    await db.execute('''
    CREATE TABLE clients_projects (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      client_name TEXT NOT NULL,
      project_name TEXT NOT NULL,
      UNIQUE(client_name, project_name)
    )
  ''');

    // App settings (for entry count)
    await db.execute('''
    CREATE TABLE app_settings (
      key TEXT PRIMARY KEY,
      value TEXT
    )
  ''');
  }

  Future<int> insertEntry(TimeEntry entry) async {
    final db = await database;
    return await db.insert('time_entries', entry.toMap());
  }

  // Import clients/projects from CSV
  Future<void> importClientsProjects(List<List<dynamic>> csvData) async {
    final db = await database;

    // Clear existing data
    await db.delete('clients_projects');

    // Skip header row, import rest
    for (int i = 1; i < csvData.length; i++) {
      if (csvData[i].length >= 2) {
        await db.insert('clients_projects', {
          'client_name': csvData[i][0].toString(),
          'project_name': csvData[i][1].toString(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
  }

  // Save employee ID
  Future<void> saveEmployeeId(String employeeId) async {
    final db = await database;
    await db.delete('app_settings', where: 'key = ?', whereArgs: ['employee_id']);
    await db.insert('app_settings', {
      'key': 'employee_id',
      'value': employeeId,
    });
  }

// Get employee ID
  Future<String?> getEmployeeId() async {
    final db = await database;
    final result = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['employee_id'],
    );

    if (result.isEmpty) return null;
    return result.first['value'] as String;
  }

// Get all clients
  Future<List<String>> getClients() async {
    final db = await database;
    final result = await db.rawQuery(
        'SELECT DISTINCT client_name FROM clients_projects ORDER BY client_name'
    );
    return result.map((row) => row['client_name'] as String).toList();
  }

// Get projects for a client
  Future<List<String>> getProjects(String clientName) async {
    final db = await database;
    final result = await db.query(
      'clients_projects',
      where: 'client_name = ?',
      whereArgs: [clientName],
      orderBy: 'project_name',
    );
    return result.map((row) => row['project_name'] as String).toList();
  }

// Check entry limit (50 max for free)
  Future<bool> canAddEntry() async {
    final db = await database;
    final count = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM time_entries')
    );
    return (count ?? 0) < 50;
  }

  Future<int> getEntryCount() async {
    final db = await database;
    return Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM time_entries')
    ) ?? 0;
  }

  // Save running timer state
  Future<void> saveTimerState({
    required String clientName,
    required String projectName,
    required DateTime startTime,
  }) async {
    final db = await database;
    await db.delete('app_settings', where: 'key = ?', whereArgs: ['active_timer']);
    await db.insert('app_settings', {
      'key': 'active_timer',
      'value': jsonEncode({
        'client': clientName,
        'project': projectName,
        'start': startTime.toIso8601String(),
      }),
    });
  }

// Load running timer state
  Future<Map<String, dynamic>?> loadTimerState() async {
    final db = await database;
    final result = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['active_timer'],
    );

    if (result.isEmpty) return null;
    return jsonDecode(result.first['value'] as String);
  }

// Clear timer state when stopped
  Future<void> clearTimerState() async {
    final db = await database;
    await db.delete('app_settings', where: 'key = ?', whereArgs: ['active_timer']);
  }

  Future<List<TimeEntry>> getTodaysEntries() async {
    final db = await database;
    final today = DateTime.now();
    final startOfDay = DateTime(today.year, today.month, today.day).toIso8601String();

    final maps = await db.query(
      'time_entries',
      where: 'start_time >= ?',
      whereArgs: [startOfDay],
      orderBy: 'start_time DESC',
    );

    return maps.map((map) => TimeEntry.fromMap(map)).toList();
  }
// Get only un-exported entries (for display)
  Future<List<TimeEntry>> getUnexportedEntries() async {
    final db = await database;
    final maps = await db.query(
      'time_entries',
      where: 'is_exported = 0',
      orderBy: 'start_time DESC',
    );
    return maps.map((map) => TimeEntry.fromMap(map)).toList();
  }

// Mark entries as exported
  Future<void> markEntriesAsExported(List<int> entryIds) async {
    final db = await database;
    for (final id in entryIds) {
      await db.update(
        'time_entries',
        {'is_exported': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  // Get all client/project combinations for management screen
  Future<List<Map<String, String>>> getAllProjects() async {
    final db = await database;
    final result = await db.query(
      'clients_projects',
      orderBy: 'client_name, project_name',
    );

    return result.map((row) => {
      'client_name': row['client_name'] as String,
      'project_name': row['project_name'] as String,
    }).toList();
  }

// Delete a specific project
  Future<void> deleteProject(String clientName, String projectName) async {
    final db = await database;

    // Delete the project from clients_projects table
    await db.delete(
      'clients_projects',
      where: 'client_name = ? AND project_name = ?',
      whereArgs: [clientName, projectName],
    );

    // Client cleanup happens automatically - if no projects remain for a client,
    // they won't appear in getClients() query results
  }

// Delete all projects and clients (nuclear option)
  Future<void> deleteAllProjects() async {
    final db = await database;
    await db.delete('clients_projects');
  }

// Get all entries (for viewing history)
  Future<List<TimeEntry>> getAllEntries() async {
    final db = await database;
    final maps = await db.query(
      'time_entries',
      orderBy: 'start_time DESC',
    );
    return maps.map((map) => TimeEntry.fromMap(map)).toList();
  }
  Future<int> updateEntry(TimeEntry entry) async {
    final db = await database;
    return await db.update(
      'time_entries',
      entry.toMap(),
      where: 'id = ?',
      whereArgs: [entry.id],
    );
  }
}