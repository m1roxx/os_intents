import 'package:os_intents/os_intents.dart';

import 'task_repo.dart';

part 'intents.os_intents.g.dart';

/// Creates a task without ever showing the app.
///
/// `Execution.background` is the whole point: the user says the phrase, the
/// task appears, nothing takes over the screen.
@AppIntent(
  title: 'Add task',
  description: 'Creates a new task in the Inbox',
  phrases: [r'Add a task to $app', r'New $app task'],
  systemImageName: 'plus.circle',
  execution: Execution.background,
)
Future<IntentResult> addTask({
  @Param(title: 'Title', requestValueDialog: 'What should the task be called?')
  required String title,
  @Param(title: 'Due date') DateTime? dueDate,
  @Param(title: 'Project') ProjectEntity? project,
}) async {
  final task = await TaskRepo.instance.create(
    title: title,
    dueDate: dueDate,
    projectId: project?.id,
  );
  return IntentResult.dialog('Added "${task.title}"');
}

/// Read-only, so no engine has to start at all.
@AppIntent(
  title: 'Tasks due today',
  phrases: [r"What's due today in $app"],
  systemImageName: 'calendar',
  execution: Execution.static_,
  showsSnippet: true,
)
Future<IntentResult> dueToday() async {
  final tasks = await TaskRepo.instance.dueToday();
  return IntentResult.snippet(
    SnippetSpec(
      title: 'Due today',
      subtitle: '${tasks.length} task(s)',
      rows: [for (final t in tasks.take(3)) SnippetRow(t.title, t.projectName)],
      imageSystemName: 'calendar',
    ),
  );
}

/// No phrases: reachable from the Shortcuts app and Spotlight, but never by
/// voice. Perfectly normal for actions that are awkward to say out loud.
@AppIntent(
  title: 'Complete task',
  description: 'Marks a task as done',
  execution: Execution.background,
)
Future<IntentResult> completeTask({
  @Param(title: 'Task') required String taskId,
}) async {
  await TaskRepo.instance.complete(taskId);
  return const IntentResult.done();
}

/// Lets the user say "add a task to **Groceries**" and have the OS resolve
/// which project that is before the handler runs.
@AppEntity(typeName: 'Project', displayName: 'Project')
class ProjectEntity {
  const ProjectEntity({required this.id, required this.name, this.teamName});

  @EntityId()
  final String id;

  @EntityDisplay(title: true)
  final String name;

  @EntityDisplay(subtitle: true)
  final String? teamName;
}

@EntityQuery(ProjectEntity)
class ProjectResolver implements EntityResolver<ProjectEntity> {
  @override
  Future<List<ProjectEntity>> byIds(List<String> ids) =>
      TaskRepo.instance.projectsByIds(ids);

  @override
  Future<List<ProjectEntity>> matching(String query) =>
      TaskRepo.instance.searchProjects(query);

  @override
  Future<List<ProjectEntity>> suggested() =>
      TaskRepo.instance.recentProjects(limit: 5);
}
