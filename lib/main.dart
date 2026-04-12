// lib/main.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'models.dart';
import 'database.dart';
import 'project_management_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Time Tracker Lite',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const TimerScreen(),
    );
  }
}

class TimerScreen extends StatefulWidget {
  const TimerScreen({super.key});

  @override
  State<TimerScreen> createState() => _TimerScreenState();
}

class _TimerScreenState extends State<TimerScreen> {
  final _dbHelper = AppDatabase();

  List<String> _clients = [];
  String? _selectedClient;
  String? _selectedProject;
  String? _employeeId;
  List<String> _availableProjects = [];

  bool _isRunning = false;
  DateTime? _startTime;
  Duration _elapsed = Duration.zero;
  Timer? _timer;

  List<TimeEntry> _todaysEntries = [];

  @override
  void initState() {
    super.initState();
    _checkEmployeeId();
    _loadClientsAndProjects();
    _loadTodaysEntries();
    _restoreTimerState();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _checkEmployeeId() async {
    final employeeId = await _dbHelper.getEmployeeId();
    if (employeeId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showEmployeeIdSetup();
      });
    } else {
      setState(() {
        _employeeId = employeeId;
      });
    }
  }

  Future<void> _showEmployeeIdSetup() async {
    final controller = TextEditingController();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Welcome to Time Tracker Lite'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Please enter your Employee ID or name:'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Employee ID',
                hintText: 'e.g., EMP-101 or John Smith',
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                await _dbHelper.saveEmployeeId(controller.text);
                setState(() {
                  _employeeId = controller.text;
                });
                if (mounted) Navigator.pop(context);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // UPDATED - Made dialog scrollable to fix overflow
  Future<String?> _showWorkDetailsDialog() async {
    final controller = TextEditingController();

    return await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Work Details'),
        content: SingleChildScrollView( // ADDED - Makes content scrollable
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('What work was performed? (optional)'),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Work Details',
                  hintText: 'e.g., Installed valve and ran electrical',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
                autofocus: true,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Skip'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.isNotEmpty ? controller.text : null),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // NEW - Show work details in a view-only dialog
  void _showWorkDetailsViewDialog(String workDetails) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Work Performed'),
        content: SingleChildScrollView(
          child: Text(workDetails),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreTimerState() async {
    final timerState = await _dbHelper.loadTimerState();
    if (timerState != null) {
      final startTime = DateTime.parse(timerState['start']);
      setState(() {
        _selectedClient = timerState['client'];
        _selectedProject = timerState['project'];
        _startTime = startTime;
        _isRunning = true;
        _elapsed = DateTime.now().difference(startTime);
      });

      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _elapsed = DateTime.now().difference(_startTime!);
        });
      });
    }
  }

  Future<void> _loadClientsAndProjects() async {
    final clients = await _dbHelper.getClients();
    setState(() {
      _clients = clients;
    });
  }

  Future<void> _loadTodaysEntries() async {
    final entries = await _dbHelper.getUnexportedEntries();
    setState(() {
      _todaysEntries = entries;
    });
  }

  Future<void> _onClientChanged(String? client) async {
    if (client == null) {
      setState(() {
        _selectedClient = null;
        _selectedProject = null;
        _availableProjects = [];
      });
      return;
    }

    final projects = await _dbHelper.getProjects(client);
    setState(() {
      _selectedClient = client;
      _selectedProject = null;
      _availableProjects = projects;
    });
  }

  Future<void> _startTimer() async {
    if (_selectedClient == null || _selectedProject == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select client and project')),
      );
      return;
    }

    final startTime = DateTime.now();

    await _dbHelper.saveTimerState(
      clientName: _selectedClient!,
      projectName: _selectedProject!,
      startTime: startTime,
    );

    setState(() {
      _isRunning = true;
      _startTime = startTime;
      _elapsed = Duration.zero;
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _elapsed = DateTime.now().difference(_startTime!);
      });
    });
  }

  Future<void> _stopTimer() async {
    _timer?.cancel();
    await _dbHelper.clearTimerState();

    final canAdd = await _dbHelper.canAddEntry();
    if (!canAdd) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Free trial limit reached (50 entries). Upgrade to Pro!'),
            duration: Duration(seconds: 5),
          ),
        );
      }
      setState(() {
        _isRunning = false;
        _startTime = null;
        _elapsed = Duration.zero;
      });
      return;
    }

    final workDetails = await _showWorkDetailsDialog();

    final entry = TimeEntry(
      clientName: _selectedClient!,
      projectName: _selectedProject!,
      startTime: _startTime!,
      endTime: DateTime.now(),
      notes: workDetails,
    );

    await _dbHelper.insertEntry(entry);
    await _loadTodaysEntries();

    setState(() {
      _isRunning = false;
      _startTime = null;
      _elapsed = Duration.zero;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Time entry saved!')),
      );
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(duration.inHours);
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$hours:$minutes:$seconds';
  }

  Future<void> _importClientsProjectsCSV() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );

      if (result == null) return;

      final file = File(result.files.single.path!);
      final csvString = await file.readAsString();

      final csvData = const CsvToListConverter().convert(csvString);

      if (csvData.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('CSV file is empty')),
          );
        }
        return;
      }

      await _dbHelper.importClientsProjects(csvData);
      await _loadClientsAndProjects();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Imported ${csvData.length - 1} client/project pairs')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    }
  }

  Future<void> _exportToCSV() async {
    if (_todaysEntries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No entries to export')),
      );
      return;
    }

    if (_employeeId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Employee ID not set')),
      );
      return;
    }

    try {
      List<List<dynamic>> csvData = [
        ['Employee ID', 'Client', 'Project', 'Start Time', 'End Time', 'Duration', 'Work Details'],
        ..._todaysEntries.map((entry) {
          final duration = entry.endTime!.difference(entry.startTime);
          final hours = duration.inHours;
          final minutes = duration.inMinutes.remainder(60);
          return [
            _employeeId,
            entry.clientName,
            entry.projectName,
            DateFormat('yyyy-MM-dd HH:mm').format(entry.startTime),
            DateFormat('yyyy-MM-dd HH:mm').format(entry.endTime!),
            '${hours}h ${minutes}m',
            entry.notes ?? '',
          ];
        }),
      ];

      String csv = const ListToCsvConverter().convert(csvData);
      final directory = await getTemporaryDirectory();
      final date = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final path = '${directory.path}/time_entries_${_employeeId}_$date.csv';
      final file = File(path);
      await file.writeAsString(csv);

      await Share.shareXFiles([XFile(path)], subject: 'Time Entries $date');

      // Mark entries as exported
      final entryIds = _todaysEntries.map((e) => e.id!).toList();
      await _dbHelper.markEntriesAsExported(entryIds);
      await _loadTodaysEntries();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('CSV exported!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  Future<void> _exportToJSON() async {
    if (_todaysEntries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No entries to export')),
      );
      return;
    }

    if (_employeeId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Employee ID not set')),
      );
      return;
    }

    try {
      final exportData = {
        'employee_id': _employeeId,
        'export_date': DateTime.now().toIso8601String(),
        'entries': _todaysEntries.map((entry) {
          final duration = entry.endTime!.difference(entry.startTime);
          return {
            'client': entry.clientName,
            'project': entry.projectName,
            'start_time': entry.startTime.toIso8601String(),
            'end_time': entry.endTime!.toIso8601String(),
            'duration_seconds': duration.inSeconds,
            'work_details': entry.notes,
          };
        }).toList(),
      };

      final jsonString = const JsonEncoder.withIndent('  ').convert(exportData);
      final directory = await getTemporaryDirectory();
      final date = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final path = '${directory.path}/time_entries_${_employeeId}_$date.txt';
      final file = File(path);
      await file.writeAsString(jsonString);

      await Share.shareXFiles(
        [XFile(path, mimeType: 'application/json')],
        subject: 'Time Entries - $_employeeId - $date',
      );

      // Mark entries as exported
      final entryIds = _todaysEntries.map((e) => e.id!).toList();
      await _dbHelper.markEntriesAsExported(entryIds);
      await _loadTodaysEntries();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('JSON exported!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  Future<void> _showAddClientProjectDialog() async {
    final projectController = TextEditingController();
    String? selectedClient;
    bool isNewClient = false;
    final newClientController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add Project'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Client selection
              if (!isNewClient) ...[
                DropdownButtonFormField<String>(
                  value: selectedClient,
                  decoration: const InputDecoration(labelText: 'Client'),
                  items: [
                    ..._clients.map((client) => DropdownMenuItem(
                      value: client,
                      child: Text(client),
                    )),
                    const DropdownMenuItem(
                      value: '__new__',
                      child: Text('+ Add New Client'),
                    ),
                  ],
                  onChanged: (value) {
                    setDialogState(() {
                      if (value == '__new__') {
                        isNewClient = true;
                        selectedClient = null;
                      } else {
                        selectedClient = value;
                      }
                    });
                  },
                ),
              ] else ...[
                TextField(
                  controller: newClientController,
                  decoration: InputDecoration(
                    labelText: 'New Client Name',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        setDialogState(() {
                          isNewClient = false;
                          newClientController.clear();
                        });
                      },
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: projectController,
                decoration: const InputDecoration(labelText: 'Project Name'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final clientName = isNewClient ? newClientController.text : selectedClient;

                if (clientName != null && clientName.isNotEmpty && projectController.text.isNotEmpty) {
                  await _dbHelper.addProject(clientName, projectController.text);
                  await _loadClientsAndProjects();
                  if (mounted) Navigator.pop(context);
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Time Tracker Lite'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'add_client') {
                _showAddClientProjectDialog();
              } else if (value == 'manage_projects') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const ProjectManagementScreen()),
                );
              } else if (value == 'change_id') {
                _showEmployeeIdSetup();
              } else if (value == 'import_csv') {
                _importClientsProjectsCSV();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'add_client',
                child: Text('Add Client/Project'),
              ),
              const PopupMenuItem(
                value: 'manage_projects',
                child: Text('Manage Projects'),
              ),
              const PopupMenuItem(
                value: 'import_csv',
                child: Text('Import from CSV'),
              ),
              const PopupMenuItem(
                value: 'change_id',
                child: Text('Change Employee ID'),
              ),
            ],
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.share),
            tooltip: 'Export Entries',
            onSelected: (value) {
              if (value == 'json') {
                _exportToJSON();
              } else if (value == 'csv') {
                _exportToCSV();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'json',
                child: Text('Export JSON (for Main App)'),
              ),
              const PopupMenuItem(
                value: 'csv',
                child: Text('Export CSV (for Excel)'),
              ),
            ],
          ),
        ],
      ),
      body: _clients.isEmpty
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('No clients/projects found', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.upload_file),
              label: const Text('Import from CSV'),
              onPressed: _importClientsProjectsCSV,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add Manually'),
              onPressed: _showAddClientProjectDialog,
            ),
          ],
        ),
      )
          : Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              value: _selectedClient,
              decoration: const InputDecoration(
                labelText: 'Client',
                border: OutlineInputBorder(),
              ),
              items: _clients.map((client) {
                return DropdownMenuItem(value: client, child: Text(client));
              }).toList(),
              onChanged: _isRunning ? null : _onClientChanged,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _selectedProject,
              decoration: const InputDecoration(
                labelText: 'Project',
                border: OutlineInputBorder(),
              ),
              items: _availableProjects.map((project) {
                return DropdownMenuItem(value: project, child: Text(project));
              }).toList(),
              onChanged: _isRunning ? null : (value) {
                setState(() => _selectedProject = value);
              },
            ),
            const SizedBox(height: 32),
            Text(
              _formatDuration(_elapsed),
              style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 60,
              child: ElevatedButton(
                onPressed: _isRunning ? _stopTimer : _startTimer,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isRunning ? Colors.red : Colors.green,
                  foregroundColor: Colors.white,
                ),
                child: Text(
                  _isRunning ? 'STOP' : 'START',
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 32),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Pending Export', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                FutureBuilder<int>(
                  future: _dbHelper.getEntryCount(),
                  builder: (context, snapshot) {
                    final count = snapshot.data ?? 0;
                    final remaining = 50 - count;
                    return Text(
                      'Trial 50: $remaining left',
                      style: TextStyle(
                        fontSize: 14,
                        color: remaining < 10 ? Colors.red : Colors.grey[600],
                        fontWeight: FontWeight.w500,
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _todaysEntries.isEmpty
                  ? const Center(child: Text('No entries to export'))
                  : ListView.builder(
                itemCount: _todaysEntries.length,
                itemBuilder: (context, index) {
                  final entry = _todaysEntries[index];
                  final duration = entry.endTime!.difference(entry.startTime);
                  final hasNotes = entry.notes != null && entry.notes!.isNotEmpty;

                  return Card(
                    child: ListTile(
                      title: Text('${entry.clientName} - ${entry.projectName}'),
                      subtitle: Text(
                        '${DateFormat('HH:mm').format(entry.startTime)} - ${DateFormat('HH:mm').format(entry.endTime!)}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // ADDED - Show note icon if work details exist
                          if (hasNotes) ...[
                            IconButton(
                              icon: const Icon(Icons.note, size: 20),
                              onPressed: () => _showWorkDetailsViewDialog(entry.notes!),
                              tooltip: 'View work details',
                            ),
                            const SizedBox(width: 8),
                          ],
                          Text(
                            _formatDuration(duration),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}