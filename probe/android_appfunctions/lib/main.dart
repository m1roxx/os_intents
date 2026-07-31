// Probe host for the Android runtime.
//
// The self-check runs from main() rather than through the UI, for the same
// reason as on iOS: what needs proving — that a second, headless FlutterEngine
// starts inside the app process and runs Dart — is not reachable by tapping,
// and an on-device agent invoking a real AppFunction is not something a test
// can arrange.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:os_intents/os_intents.dart';

import 'intents.dart';

const _tag = 'OSINTENTS_SELFCHECK';
const bool selfCheckEnabled = bool.fromEnvironment('OS_INTENTS_SELFCHECK');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await OsIntents.install($osIntentsRegistry);

  if (selfCheckEnabled) {
    await _runSelfCheck();
  }

  runApp(const ProbeApp());
}

void _pass(String name, [String detail = '']) =>
    debugPrint('$_tag PASS $name${detail.isEmpty ? '' : ' — $detail'}');

void _fail(String name, Object detail) =>
    debugPrint('$_tag FAIL $name — $detail');

Future<void> _runSelfCheck() async {
  debugPrint('$_tag BEGIN');
  await _checkHeadlessEngine();
  await _checkUnknownIntent();
  await _checkShortcutRouting();
  debugPrint('$_tag END');
}

/// Did an app-shortcut launch reach the handler?
///
/// Only meaningful when the harness started the app with the Intent a shortcut
/// builds, so it reports SKIP otherwise rather than failing an ordinary run.
///
/// The invocation arrives from outside — the plugin reads the Activity's launch
/// Intent and calls in — so unlike every other check here there is nothing to
/// await. It polls instead, briefly.
Future<void> _checkShortcutRouting() async {
  const name = 'shortcut_routing';
  const shortcutId = String.fromEnvironment('OS_INTENTS_EXPECT_SHORTCUT');
  if (shortcutId.isEmpty) {
    debugPrint('$_tag SKIP $name — not launched from a shortcut');
    return;
  }

  for (var i = 0; i < 40; i++) {
    if (openedFromShortcut.isNotEmpty) {
      _pass(name, 'ran on the UI isolate, in the app the user is looking at');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  _fail(
    name,
    'nothing arrived for "$shortcutId" within 4s. Either the launch Intent did '
    'not match, or the manifest is missing the shortcuts meta-data.',
  );
}

/// The whole Android runtime in one check.
///
/// A pass means FlutterLoader initialised, a second FlutterEngine came up,
/// `osIntentsBackgroundEntrypoint` was found by name in the right library,
/// plugins registered, and the round trip over the method channel worked.
Future<void> _checkHeadlessEngine() async {
  const name = 'headless_engine';
  try {
    final before = createdTitles.length;
    final out = await OsIntents.debugInvokeBackground('addTask', {
      'title': 'from the self-check',
    });
    if (out == null || out['spoken'] != 'Added "from the self-check"') {
      _fail(name, 'unexpected result: $out');
      return;
    }
    final after = createdTitles.length;
    if (after != before) {
      // The UI isolate has its own copy of this list; seeing the write here
      // would mean the work never left this isolate.
      _fail(name, 'the UI isolate saw the write ($before -> $after)');
      return;
    }
    _pass(name, 'ran in a second isolate, UI list stayed at $after');
  } catch (e) {
    _fail(name, e);
  }
}

/// An id the registry does not know must fail loudly rather than hang.
Future<void> _checkUnknownIntent() async {
  const name = 'unknown_intent_fails';
  try {
    await OsIntents.debugInvokeBackground('noSuchIntent');
    _fail(name, 'it succeeded, which means errors are being swallowed');
  } catch (e) {
    if ('$e'.contains('No handler registered')) {
      _pass(name, 'reported by the Dart registry');
    } else {
      _fail(name, 'wrong error: $e');
    }
  }
}

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('AppFunctions probe')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Run ../run_android_integration.sh for the verdict.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
  );
}
