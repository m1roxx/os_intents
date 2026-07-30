import 'intents.dart';

/// Stand-in for whatever the real app uses. Kept in memory so the example has
/// no database dependency.
class Task {
  Task({
    required this.id,
    required this.title,
    this.dueDate,
    this.projectId,
    this.done = false,
  });

  final String id;
  final String title;
  final DateTime? dueDate;
  final String? projectId;
  bool done;

  String get projectName =>
      TaskRepo.instance._projects
          .where((p) => p.id == projectId)
          .map((p) => p.name)
          .firstOrNull ??
      'Inbox';
}

class TaskRepo {
  TaskRepo._();

  static final TaskRepo instance = TaskRepo._();

  final List<Task> _tasks = [];
  final List<ProjectEntity> _projects = const [
    ProjectEntity(id: 'p1', name: 'Groceries', teamName: 'Home'),
    ProjectEntity(id: 'p2', name: 'Launch', teamName: 'Work'),
  ];

  List<Task> get all => List.unmodifiable(_tasks);

  Future<Task> create({
    required String title,
    DateTime? dueDate,
    String? projectId,
  }) async {
    final task = Task(
      id: 't${_tasks.length + 1}',
      title: title,
      dueDate: dueDate,
      projectId: projectId,
    );
    _tasks.add(task);
    return task;
  }

  Future<void> complete(String id) async {
    for (final t in _tasks) {
      if (t.id == id) t.done = true;
    }
  }

  Future<List<Task>> dueToday() async {
    final now = DateTime.now();
    return _tasks
        .where(
          (t) =>
              !t.done &&
              t.dueDate != null &&
              t.dueDate!.year == now.year &&
              t.dueDate!.month == now.month &&
              t.dueDate!.day == now.day,
        )
        .toList();
  }

  Future<List<ProjectEntity>> projectsByIds(List<String> ids) async =>
      _projects.where((p) => ids.contains(p.id)).toList();

  Future<List<ProjectEntity>> searchProjects(String query) async {
    final q = query.toLowerCase();
    return _projects.where((p) => p.name.toLowerCase().contains(q)).toList();
  }

  Future<List<ProjectEntity>> recentProjects({int limit = 5}) async =>
      _projects.take(limit).toList();
}
