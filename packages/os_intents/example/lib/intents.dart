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
  @Param(title: 'Priority') Priority? priority,
}) async {
  final task = await TaskRepo.instance.create(
    title: title,
    dueDate: dueDate,
    projectId: project?.id,
  );
  final note = priority == null ? '' : ' (${priority.name})';
  return IntentResult.dialog('Added "${task.title}"$note');
}

/// A closed set, so the OS can offer the choices without asking the app.
///
/// The cheap half of "the system fills this in": an entity needs a query
/// because its values live in your data, an enum does not because they are
/// known when the code is generated. It is also the only kind of narrowing
/// Android offers — iOS gets an `AppEnum`, Android a value constraint.
@AppEnum(typeName: 'Priority', displayName: 'Priority')
enum Priority {
  @AppEnumValue(title: 'Whenever')
  whenever,
  @AppEnumValue(title: 'Normal')
  normal,
  // No title: the generator humanises the constant's own name.
  veryUrgent,
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

/// Hands a number back, so a Shortcut can feed it into its next step.
///
/// `returns:` is what puts `ReturnsValue<Int>` in the generated `perform()`.
/// Without it the action would still run and still speak, but the number would
/// have nowhere to go.
@AppIntent(
  title: 'Count tasks',
  description: 'How many tasks are open',
  execution: Execution.background,
  returns: int,
)
Future<IntentResult> countOpenTasks() async {
  final open = TaskRepo.instance.all.length;
  return IntentResult.value(open, spoken: '$open open');
}

/// No phrases: reachable from the Shortcuts app and Spotlight, but never by
/// voice. Perfectly normal for actions that are awkward to say out loud.
///
/// `confirmBeforeRunning` is the other half: the system asks first, and the
/// handler below is never called if the user says no. A property of the action,
/// decided when the code is generated — which is why it could never have been
/// something the handler returned.
@AppIntent(
  title: 'Complete task',
  description: 'Marks a task as done',
  execution: Execution.background,
  confirmBeforeRunning: 'Mark this task as done?',
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
