import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'dart:convert';
import 'models.dart';

part 'database.g.dart';

@DataClassName('TimeEntryRow')
class TimeEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get clientName => text()();
  TextColumn get projectName => text()();
  DateTimeColumn get startTime => dateTime()();
  DateTimeColumn get endTime => dateTime().nullable()();
  TextColumn get notes => text().nullable()();
  BoolColumn get isExported => boolean().withDefault(const Constant(false))();
}

class ClientsProjects extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get clientName => text()();
  TextColumn get projectName => text()();

  @override
  List<Set<Column>> get uniqueKeys => [{clientName, projectName}];
}

class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text().nullable()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [TimeEntries, ClientsProjects, AppSettings])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  Future<int> insertEntry(TimeEntry entry) => into(timeEntries).insert(
    TimeEntriesCompanion.insert(
      clientName: entry.clientName,
      projectName: entry.projectName,
      startTime: entry.startTime,
      endTime: Value(entry.endTime),
      notes: Value(entry.notes),
      isExported: Value(entry.isExported),
    ),
  );

  Future<int> updateEntry(TimeEntry entry) => (update(timeEntries)
    ..where((t) => t.id.equals(entry.id!)))
      .write(TimeEntriesCompanion(
    clientName: Value(entry.clientName),
    projectName: Value(entry.projectName),
    startTime: Value(entry.startTime),
    endTime: Value(entry.endTime),
    notes: Value(entry.notes),
    isExported: Value(entry.isExported),
  ));

  Future<List<TimeEntry>> getTodaysEntries() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));
    final rows = await (select(timeEntries)
      ..where((t) =>
      t.startTime.isBiggerOrEqualValue(start) &
      t.startTime.isSmallerThanValue(end))
      ..orderBy([(t) => OrderingTerm.desc(t.startTime)]))
        .get();
    return rows.map(_rowToEntry).toList();
  }

  Future<List<TimeEntry>> getUnexportedEntries() async {
    final rows = await (select(timeEntries)
      ..where((t) => t.isExported.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.startTime)]))
        .get();
    return rows.map(_rowToEntry).toList();
  }

  Future<List<TimeEntry>> getAllEntries() async {
    final rows = await (select(timeEntries)
      ..orderBy([(t) => OrderingTerm.desc(t.startTime)]))
        .get();
    return rows.map(_rowToEntry).toList();
  }

  Future<void> markEntriesAsExported(List<int> entryIds) async {
    await (update(timeEntries)..where((t) => t.id.isIn(entryIds)))
        .write(const TimeEntriesCompanion(isExported: Value(true)));
  }

  Future<bool> canAddEntry() async {
    final count = await getEntryCount();
    return count < 50;
  }

  Future<int> getEntryCount() async {
    final count = await customSelect(
      'SELECT COUNT(*) AS c FROM time_entries',
      readsFrom: {timeEntries},
    ).getSingle();
    return count.read<int>('c');
  }

  Future<List<String>> getClients() async {
    final rows = await (select(clientsProjects)
      ..orderBy([(t) => OrderingTerm.asc(t.clientName)]))
        .get();
    final seen = <String>{};
    return rows.map((r) => r.clientName).where((c) => seen.add(c)).toList();
  }

  Future<List<String>> getProjects(String clientName) async {
    final rows = await (select(clientsProjects)
      ..where((t) => t.clientName.equals(clientName))
      ..orderBy([(t) => OrderingTerm.asc(t.projectName)]))
        .get();
    return rows.map((r) => r.projectName).toList();
  }

  Future<List<Map<String, String>>> getAllProjects() async {
    final rows = await (select(clientsProjects)
      ..orderBy([
            (t) => OrderingTerm.asc(t.clientName),
            (t) => OrderingTerm.asc(t.projectName),
      ]))
        .get();
    return rows.map((r) => {'client': r.clientName, 'project': r.projectName}).toList();
  }

  Future<void> addProject(String clientName, String projectName) async {
    await into(clientsProjects).insertOnConflictUpdate(
      ClientsProjectsCompanion.insert(
        clientName: clientName,
        projectName: projectName,
      ),
    );
  }

  Future<void> importClientsProjects(List<List<dynamic>> csvData) async {
    await batch((b) {
      for (final row in csvData) {
        if (row.length >= 2) {
          b.insert(
            clientsProjects,
            ClientsProjectsCompanion.insert(
              clientName: row[0].toString(),
              projectName: row[1].toString(),
            ),
            mode: InsertMode.insertOrReplace,
          );
        }
      }
    });
  }

  Future<void> deleteProject(String clientName, String projectName) async {
    await (delete(clientsProjects)
      ..where((t) =>
      t.clientName.equals(clientName) &
      t.projectName.equals(projectName)))
        .go();
  }

  Future<void> deleteAllProjects() async {
    await delete(clientsProjects).go();
  }

  Future<void> saveEmployeeId(String employeeId) async {
    await into(appSettings).insertOnConflictUpdate(
      AppSettingsCompanion.insert(key: 'employee_id', value: Value(employeeId)),
    );
  }

  Future<String?> getEmployeeId() async {
    final row = await (select(appSettings)
      ..where((t) => t.key.equals('employee_id')))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> saveTimerState({
    required String clientName,
    required String projectName,
    required DateTime startTime,
  }) async {
    final payload = jsonEncode({
      'client': clientName,
      'project': projectName,
      'start': startTime.toIso8601String(),
    });
    await into(appSettings).insertOnConflictUpdate(
      AppSettingsCompanion.insert(key: 'active_timer', value: Value(payload)),
    );
  }

  Future<Map<String, dynamic>?> loadTimerState() async {
    final row = await (select(appSettings)
      ..where((t) => t.key.equals('active_timer')))
        .getSingleOrNull();
    if (row?.value == null) return null;
    return jsonDecode(row!.value!) as Map<String, dynamic>;
  }

  Future<void> clearTimerState() async {
    await (delete(appSettings)..where((t) => t.key.equals('active_timer'))).go();
  }
}

QueryExecutor _openConnection() {
  return driftDatabase(name: 'time_tracker_lite');
}

TimeEntry _rowToEntry(TimeEntryRow row) => TimeEntry(
  id: row.id,
  clientName: row.clientName,
  projectName: row.projectName,
  startTime: row.startTime,
  endTime: row.endTime,
  notes: row.notes,
  isExported: row.isExported,
);