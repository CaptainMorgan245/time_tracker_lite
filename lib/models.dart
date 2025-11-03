// lib/models.dart

class TimeEntry {
  final int? id;
  final String clientName;
  final String projectName;
  final DateTime startTime;
  final DateTime? endTime;
  final String? notes;
  final bool isExported;

  TimeEntry({
    this.id,
    required this.clientName,
    required this.projectName,
    required this.startTime,
    this.endTime,
    this.notes,
    this.isExported = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'client_name': clientName,
      'project_name': projectName,
      'start_time': startTime.toIso8601String(),
      'end_time': endTime?.toIso8601String(),
      'notes': notes,
      'is_exported': isExported ? 1 : 0,
    };
  }

  factory TimeEntry.fromMap(Map<String, dynamic> map) {
    return TimeEntry(
      id: map['id'],
      clientName: map['client_name'],
      projectName: map['project_name'],
      startTime: DateTime.parse(map['start_time']),
      endTime: map['end_time'] != null ? DateTime.parse(map['end_time']) : null,
      notes: map['notes'],
      isExported: (map['is_exported'] ?? 0) == 1,
    );
  }
}