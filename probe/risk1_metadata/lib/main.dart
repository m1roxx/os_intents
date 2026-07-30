// Probe app for Risk #1. The Dart side is deliberately trivial — the whole
// experiment happens at build time, in App Intents metadata extraction.
//
// What matters is that this app links os_intents (and therefore the
// os_intents_ios plugin module, which declares ProbePodIntent) without ever
// referencing that intent from Dart or from the Runner target.

import 'package:flutter/material.dart';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'os_intents — Risk #1 probe',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: Scaffold(
        appBar: AppBar(title: const Text('Risk #1 probe')),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Text(
                'Build this app, then inspect Runner.app/Metadata.appintents.',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('Variant C — ProbeRunnerIntent, declared in the Runner target.'),
              Text('Variant A/B — ProbePodIntent, declared in the plugin module.'),
              Text('Run ../run_probe.sh for the verdict.'),
            ],
          ),
        ),
      ),
    );
  }
}
