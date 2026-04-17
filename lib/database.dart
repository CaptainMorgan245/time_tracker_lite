import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'dart:convert';
import 'models.dart';

part 'database.g.dart';

// ── Table definitions ─────────────────────────────────────────────────────────

@DataClassName('ClientRow')
class Clients extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().unique()();
}

@DataClassName('ProjectRow')
class Projects extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get clientId => integer().references(Clients, #id)();
  TextColumn get name => text()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {clientId, name}
      ];
}

@DataClassName('TimeEntryRow')
class TimeEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  // FK columns — nullable so ALTER TABLE ADD COLUMN succeeds during migration;
  // all new writes will always populate them.
  IntColumn get clientId => integer().nullable().references(Clients, #id)();
  IntColumn get projectId => integer().nullable().references(Projects, #id)();
  // Kept as denormalised display fields (populated on every write).
  TextColumn get clientName => text()();
  TextColumn get projectName => text()();
  DateTimeColumn get startTime => dateTime()();
  DateTimeColumn get endTime => dateTime().nullable()();
  TextColumn get notes => text().nullable()();
  BoolColumn get isExported => boolean().withDefault(const Constant(false))();
}

class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text().nullable()();

  @override
  Set<Column> get primaryKey => {key};
}

// ── Helper type ───────────────────────────────────────────────────────────────

class ProjectWithClient {
  final int projectId;
  final int clientId;
  final String clientName;
  final String projectName;

  const ProjectWithClient({
    required this.projectId,
    required this.clientId,
    required this.clientName,
    required this.projectName,
  });
}

// ── Database ──────────────────────────────────────────────────────────────────

@DriftDatabase(tables: [Clients, Projects, TimeEntries, AppSettings])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // 1. Create the new normalised tables.
            await m.createTable(clients);
            await m.createTable(projects);

            // 2. Add FK columns to time_entries (nullable — no default required).
            await m.addColumn(timeEntries, timeEntries.clientId);
            await m.addColumn(timeEntries, timeEntries.projectId);

            // 3. Seed clients from distinct names in the old lookup table.
            await customStatement('''
              INSERT OR IGNORE INTO clients (name)
              SELECT DISTINCT client_name FROM clients_projects
              ORDER BY client_name
            ''');

            // 4. Seed projects, resolving the new client FK.
            await customStatement('''
              INSERT OR IGNORE INTO projects (client_id, name)
              SELECT c.id, cp.project_name
              FROM clients_projects cp
              JOIN clients c ON c.name = cp.client_name
            ''');

            // 5. Back-fill time_entries.client_id.
            await customStatement('''
              UPDATE time_entries
              SET client_id = (
                SELECT id FROM clients WHERE name = time_entries.client_name
              )
            ''');

            // 6. Back-fill time_entries.project_id.
            await customStatement('''
              UPDATE time_entries
              SET project_id = (
                SELECT p.id FROM projects p
                WHERE p.client_id = time_entries.client_id
                  AND p.name = time_entries.project_name
              )
            ''');

            // 7. Drop the now-redundant lookup table.
            await customStatement('DROP TABLE IF EXISTS clients_projects');
          }
        },
      );

  // ── Time entries ─────────────────────────────────────────────────────────────

  // Resolves client/project IDs by name so callers using the existing TimeEntry
  // model (clientName / projectName) continue to work until models.dart is updated.
  Future<int> insertEntry(TimeEntry entry) async {
    final clientRow = await (select(clients)
          ..where((c) => c.name.equals(entry.clientName)))
        .getSingleOrNull();
    final projectRow = clientRow == null
        ? null
        : await (select(projects)
              ..where((p) =>
                  p.clientId.equals(clientRow.id) &
                  p.name.equals(entry.projectName)))
            .getSingleOrNull();

    return into(timeEntries).insert(
      TimeEntriesCompanion.insert(
        clientId: Value(clientRow?.id),
        projectId: Value(projectRow?.id),
        clientName: entry.clientName,
        projectName: entry.projectName,
        startTime: entry.startTime,
        endTime: Value(entry.endTime),
        notes: Value(entry.notes),
        isExported: Value(entry.isExported),
      ),
    );
  }

  Future<int> updateEntry(TimeEntry entry) async {
    final clientRow = await (select(clients)
          ..where((c) => c.name.equals(entry.clientName)))
        .getSingleOrNull();
    final projectRow = clientRow == null
        ? null
        : await (select(projects)
              ..where((p) =>
                  p.clientId.equals(clientRow.id) &
                  p.name.equals(entry.projectName)))
            .getSingleOrNull();

    return (update(timeEntries)..where((t) => t.id.equals(entry.id!)))
        .write(TimeEntriesCompanion(
      clientId: Value(clientRow?.id),
      projectId: Value(projectRow?.id),
      clientName: Value(entry.clientName),
      projectName: Value(entry.projectName),
      startTime: Value(entry.startTime),
      endTime: Value(entry.endTime),
      notes: Value(entry.notes),
      isExported: Value(entry.isExported),
    ));
  }

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

  Future<int> getEntryCount() async {
    final count = await customSelect(
      'SELECT COUNT(*) AS c FROM time_entries',
      readsFrom: {timeEntries},
    ).getSingle();
    return count.read<int>('c');
  }

  Future<void> deleteEntry(int id) async {
    await (delete(timeEntries)..where((t) => t.id.equals(id))).go();
  }

  // ── Clients ───────────────────────────────────────────────────────────────────

  Future<List<ClientRow>> getClients() {
    return (select(clients)
          ..orderBy([(c) => OrderingTerm.asc(c.name)]))
        .get();
  }

  Future<ClientRow?> getClientByName(String name) {
    return (select(clients)..where((c) => c.name.equals(name)))
        .getSingleOrNull();
  }

  /// Inserts the client if it does not exist; returns its id either way.
  Future<int> insertClient(String name) async {
    await into(clients).insert(
      ClientsCompanion.insert(name: name),
      mode: InsertMode.insertOrIgnore,
    );
    final row =
        await (select(clients)..where((c) => c.name.equals(name))).getSingle();
    return row.id;
  }

  // ── Projects ──────────────────────────────────────────────────────────────────

  Future<List<ProjectRow>> getProjects(int clientId) {
    return (select(projects)
          ..where((p) => p.clientId.equals(clientId))
          ..orderBy([(p) => OrderingTerm.asc(p.name)]))
        .get();
  }

  Future<List<ProjectWithClient>> getAllProjects() async {
    final rows = await (select(projects).join([
      innerJoin(clients, clients.id.equalsExp(projects.clientId)),
    ])
          ..orderBy([
            OrderingTerm.asc(clients.name),
            OrderingTerm.asc(projects.name),
          ]))
        .get();
    return rows.map((row) {
      final p = row.readTable(projects);
      final c = row.readTable(clients);
      return ProjectWithClient(
        projectId: p.id,
        clientId: c.id,
        clientName: c.name,
        projectName: p.name,
      );
    }).toList();
  }

  /// Inserts the project if it does not exist; returns its id either way.
  Future<int> addProject(int clientId, String projectName) async {
    await into(projects).insert(
      ProjectsCompanion.insert(clientId: clientId, name: projectName),
      mode: InsertMode.insertOrIgnore,
    );
    final row = await (select(projects)
          ..where((p) =>
              p.clientId.equals(clientId) & p.name.equals(projectName)))
        .getSingle();
    return row.id;
  }

  Future<void> deleteProject(int projectId) {
    return (delete(projects)..where((p) => p.id.equals(projectId))).go();
  }

  Future<void> deleteAllProjects() {
    // Delete projects before clients to respect FK ordering.
    return transaction(() async {
      await delete(projects).go();
      await delete(clients).go();
    });
  }

  Future<void> importClientsProjects(List<List<dynamic>> csvData) async {
    await transaction(() async {
      for (final row in csvData) {
        if (row.length >= 2) {
          final clientId = await insertClient(row[0].toString());
          await into(projects).insert(
            ProjectsCompanion.insert(
                clientId: clientId, name: row[1].toString()),
            mode: InsertMode.insertOrIgnore,
          );
        }
      }
    });
  }

  // ── App settings ──────────────────────────────────────────────────────────────

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
    required int clientId,
    required int projectId,
    required DateTime startTime,
  }) async {
    final payload = jsonEncode({
      'client_id': clientId,
      'project_id': projectId,
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
    await (delete(appSettings)..where((t) => t.key.equals('active_timer')))
        .go();
  }
}

// ── Connection ────────────────────────────────────────────────────────────────

QueryExecutor _openConnection() {
  return driftDatabase(
    name: 'time_tracker_lite',
    web: DriftWebOptions(
      sqlite3Wasm: Uri.parse('sqlite3.wasm'),
      driftWorker: Uri.parse('drift_worker.worker.js'),
    ),
  );
}

// ── Row mapper ────────────────────────────────────────────────────────────────

TimeEntry _rowToEntry(TimeEntryRow row) => TimeEntry(
      id: row.id,
      clientName: row.clientName,
      projectName: row.projectName,
      startTime: row.startTime,
      endTime: row.endTime,
      notes: row.notes,
      isExported: row.isExported,
    );
