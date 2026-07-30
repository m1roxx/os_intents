import 'package:flutter/material.dart';
import 'package:os_intents/os_intents.dart';

import 'intents.dart';
import 'task_repo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // $osIntentsRegistry is generated from the annotations in intents.dart.
  // Install it before runApp: an intent can be what launched the app, and the
  // native side buffers that invocation only until this resolves.
  await OsIntents.install($osIntentsRegistry);

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'os_intents example',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    home: const TaskListPage(),
  );
}

class TaskListPage extends StatefulWidget {
  const TaskListPage({super.key});

  @override
  State<TaskListPage> createState() => _TaskListPageState();
}

class _TaskListPageState extends State<TaskListPage> {
  @override
  Widget build(BuildContext context) {
    final tasks = TaskRepo.instance.all;
    return Scaffold(
      appBar: AppBar(title: const Text('Tasks')),
      body: tasks.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No tasks yet.\n\n'
                  'Try "Add a task to os_intents example" in Shortcuts, '
                  'or use the button below.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              children: [
                for (final t in tasks)
                  CheckboxListTile(
                    value: t.done,
                    title: Text(t.title),
                    subtitle: Text(t.projectName),
                    onChanged: (_) async {
                      await completeTask(taskId: t.id);
                      setState(() {});
                    },
                  ),
              ],
            ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        spacing: 12,
        children: [
          // Proves the headless path end to end: this runs addTask in the
          // background engine's isolate, which has its own TaskRepo. The task
          // therefore does NOT appear in the list above — that absence is the
          // evidence a second isolate really ran it.
          FloatingActionButton.extended(
            heroTag: 'bg',
            onPressed: () async {
              final result = await OsIntents.debugInvokeBackground('addTask', {
                'title': 'From the background isolate',
              });
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('background engine → $result')),
              );
            },
            icon: const Icon(Icons.bolt),
            label: const Text('Run headless'),
          ),
          FloatingActionButton(
            heroTag: 'fg',
            onPressed: () async {
              // The same function the OS calls — nothing about it is special.
              await addTask(title: 'Task ${TaskRepo.instance.all.length + 1}');
              setState(() {});
            },
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
