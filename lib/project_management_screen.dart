// lib/project_management_screen.dart

import 'package:flutter/material.dart';
import 'database.dart';

class ProjectManagementScreen extends StatefulWidget {
  const ProjectManagementScreen({super.key});

  @override
  State<ProjectManagementScreen> createState() => _ProjectManagementScreenState();
}

class _ProjectManagementScreenState extends State<ProjectManagementScreen> {
  final _db = AppDatabase();
  List<ProjectWithClient> _projects = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    setState(() => _isLoading = true);
    final projects = await _db.getAllProjects();
    setState(() {
      _projects = projects;
      _isLoading = false;
    });
  }

  Future<void> _renameProject(ProjectWithClient project) async {
    final controller = TextEditingController(text: project.projectName);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Project'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Project Name'),
          autofocus: true,
          onSubmitted: (_) => Navigator.pop(context, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final newName = controller.text.trim();
    if (newName.isEmpty || newName == project.projectName) return;

    await _db.renameProject(project.projectId, newName);
    await _loadProjects();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Renamed to "$newName"')),
      );
    }
  }

  Future<void> _deleteProject(ProjectWithClient project) async {
    final entryCount = await _db.getEntryCountForProject(project.projectId);
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Project'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Delete "${project.projectName}"?'),
            const SizedBox(height: 8),
            if (entryCount > 0) ...[
              Text(
                'Warning: $entryCount time ${entryCount == 1 ? 'entry' : 'entries'} '
                'recorded against this project will be orphaned.',
                style: const TextStyle(color: Colors.orange),
              ),
              const SizedBox(height: 8),
            ],
            const Text('This cannot be undone.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await _db.deleteProject(project.projectId);
    await _loadProjects();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted "${project.projectName}"')),
      );
    }
  }

  Future<void> _deleteAllProjects() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete All Projects'),
        content: const Text('Delete ALL projects and clients?\n\nThis cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _db.deleteAllProjects();
      await _loadProjects();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All projects deleted')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Projects'),
        actions: [
          if (_projects.isNotEmpty)
            TextButton(
              onPressed: _deleteAllProjects,
              child: const Text(
                'Delete All',
                style: TextStyle(color: Colors.red),
              ),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _projects.isEmpty
              ? const Center(
                  child: Text(
                    'No projects found.\n\nProjects are created when you start time tracking.',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _projects.length,
                  itemBuilder: (context, index) {
                    final project = _projects[index];
                    return Card(
                      child: ListTile(
                        title: Text(project.projectName),
                        subtitle: Text('Client: ${project.clientName}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit),
                              tooltip: 'Rename',
                              onPressed: () => _renameProject(project),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              tooltip: 'Delete',
                              onPressed: () => _deleteProject(project),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
