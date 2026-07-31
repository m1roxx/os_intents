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
  // A required parameter, so this gets no launcher shortcut — a tap has no way
  // to supply one. The capability is different: Assistant fills task.name from
  // what the user said before anything is launched.
  androidCapability: 'actions.intent.CREATE_TASK',
)
Future<IntentResult> addTask({
  @Param(
    title: 'Title',
    description: 'The title of the task',
    androidCapabilityParameter: 'task.name',
  )
  required String title,
  @Param(title: 'Due date') DateTime? dueDate,
}) async {
  // Per-isolate on purpose: the self-check asserts the UI isolate's copy does
  // NOT grow, which is what proves the work happened somewhere else.
  createdTitles.add(title);
  return IntentResult.dialog('Added "$title"');
}

/// Titles created in whichever isolate is running.
final List<String> createdTitles = [];

@AppIntent(title: 'Tasks due today', execution: Execution.static_)
Future<IntentResult> dueToday() async =>
    const IntentResult.dialog('Nothing due today');

// Foreground on purpose: it must NOT appear in the generated Kotlin, because an
// AppFunctionService has no Activity to bring forward. It is exactly what the
// app-shortcuts layer is for, though — no parameters, and opening the app is
// the point rather than a compromise.
@AppIntent(title: 'Open inbox')
Future<IntentResult> openInbox() async {
  openedFromShortcut.add(DateTime.now());
  return const IntentResult.done();
}

/// Invocations that arrived from an app shortcut, in the UI isolate.
///
/// The shortcuts layer always runs here, unlike an AppFunction: a shortcut
/// starts the Activity, so the handler sees the state the user is looking at.
final List<DateTime> openedFromShortcut = [];
