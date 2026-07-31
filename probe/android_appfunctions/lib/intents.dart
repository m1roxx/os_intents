// Input for the Android emitter probe. Deliberately covers the shapes that
// differ between platforms: a required and an optional parameter, a date, and
// an intent with no parameters at all.

import 'package:os_intents/os_intents.dart';

part 'intents.os_intents.g.dart';

@AppIntent(
  title: 'Add task',
  description: 'Creates a new task in the Inbox',
  phrases: [r'Add a task to $app'],
  execution: Execution.background,
)
Future<IntentResult> addTask({
  @Param(title: 'Title', description: 'The title of the task')
  required String title,
  @Param(title: 'Due date') DateTime? dueDate,
}) async => IntentResult.dialog('Added "$title"');

@AppIntent(
  title: 'Tasks due today',
  execution: Execution.static_,
)
Future<IntentResult> dueToday() async =>
    const IntentResult.dialog('Nothing due today');

// Foreground on purpose: it must NOT appear in the generated Kotlin, because an
// AppFunctionService has no Activity to bring forward.
@AppIntent(title: 'Open inbox')
Future<IntentResult> openInbox() async => const IntentResult.done();
