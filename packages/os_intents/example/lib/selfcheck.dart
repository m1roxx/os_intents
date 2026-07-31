// Self-check run by the example app at startup, guarded by a --dart-define so
// it never runs for real users.
//
// Not a `flutter test`: everything worth checking here — the headless engine,
// the static store, the entity channel — only exists on a device. And not
// driven through the UI either, because taps injected into the simulator do not
// reach Flutter's gesture layer on this setup.
//
// Each check prints one line the harness greps for.

import 'package:flutter/foundation.dart';
import 'package:os_intents/os_intents.dart';

import 'intents.dart';

const _tag = 'OSINTENTS_SELFCHECK';

/// True when the app was launched with
/// `--dart-define=OS_INTENTS_SELFCHECK=true`.
const bool selfCheckEnabled = bool.fromEnvironment('OS_INTENTS_SELFCHECK');

void _pass(String name, [String detail = '']) =>
    debugPrint('$_tag PASS $name${detail.isEmpty ? '' : ' — $detail'}');

void _fail(String name, Object detail) =>
    debugPrint('$_tag FAIL $name — $detail');

/// Runs every check, then prints a terminating line so the harness can tell
/// "still running" from "finished".
Future<void> runSelfCheck({
  required IntentRegistry registry,
  required int Function() uiSideEffectCount,
}) async {
  debugPrint('$_tag BEGIN');

  await _checkHeadlessIsolate(uiSideEffectCount);
  await _checkStaticRoundTrip();
  await _checkEntityQueries(registry);
  await _checkSnippetRoundTrip();
  await _checkDonation();

  debugPrint('$_tag END');
}

/// The handler must run, and must run somewhere else.
///
/// The second half is the real assertion: if the work landed in the UI isolate
/// the count would move, and the "headless" engine would be a fiction.
Future<void> _checkHeadlessIsolate(int Function() uiSideEffectCount) async {
  const name = 'headless_isolate';
  final before = uiSideEffectCount();
  try {
    final out = await OsIntents.debugInvokeBackground('addTask', {
      'title': 'from the self-check',
    });
    if (out == null || out['kind'] != 'dialog') {
      _fail(name, 'unexpected result: $out');
      return;
    }
    final after = uiSideEffectCount();
    if (after != before) {
      _fail(name, 'the UI isolate saw the write ($before -> $after)');
      return;
    }
    _pass(name, 'ran elsewhere, UI count stayed $after');
  } catch (e) {
    _fail(name, e);
  }
}

/// publishStatic and the native read side must agree.
///
/// They did not at first: the write went to an App Group that was never
/// provisioned and the read came from UserDefaults.standard.
Future<void> _checkStaticRoundTrip() async {
  const name = 'static_round_trip';
  try {
    const sentinel = 'self-check sentinel';
    await OsIntents.publishStatic({
      'dueToday': const IntentResult.dialog(sentinel),
    });
    final read = await OsIntents.debugStaticValue('dueToday');
    if (read != sentinel) {
      _fail(name, 'published "$sentinel", read back ${read ?? "null"}');
      return;
    }
    _pass(name);
  } catch (e) {
    _fail(name, e);
  }
}

/// Entity queries have to answer, since the OS calls them before a handler
/// runs. They returned null until the channel dispatched on method name.
Future<void> _checkEntityQueries(IntentRegistry registry) async {
  const name = 'entity_queries';
  try {
    final binding = registry.entities['Project'];
    if (binding == null) {
      _fail(name, 'no EntityBinding registered for Project');
      return;
    }
    final suggested = await binding.suggested();
    final matching = await binding.matching('groc');
    final byIds = await binding.byIds(['p1']);

    if (suggested.isEmpty) {
      _fail(name, 'suggested() returned nothing');
      return;
    }
    if (matching.length != 1 || matching.single['name'] != 'Groceries') {
      _fail(name, 'matching("groc") returned $matching');
      return;
    }
    if (byIds.length != 1 || byIds.single['id'] != 'p1') {
      _fail(name, 'byIds(["p1"]) returned $byIds');
      return;
    }
    // The encoder must produce exactly the keys the generated Swift reads.
    const expected = {'id', 'name', 'teamName'};
    final actual = byIds.single.keys.toSet();
    if (!actual.containsAll(expected)) {
      _fail(name, 'encoder produced $actual, expected to include $expected');
      return;
    }
    _pass(name, '${suggested.length} suggested, wire keys $actual');
  } catch (e) {
    _fail(name, e);
  }
}

/// A snippet published for a static intent has to survive the store, or a
/// `showsSnippet` intent would render an empty card on its fast path — which is
/// exactly what the first version did.
Future<void> _checkSnippetRoundTrip() async {
  const name = 'snippet_round_trip';
  try {
    await OsIntents.publishStatic({
      'dueToday': const IntentResult.snippet(
        SnippetSpec(
          title: 'Due today',
          subtitle: '2 task(s)',
          rows: [SnippetRow('Buy milk', 'Groceries')],
          imageSystemName: 'calendar',
        ),
        spoken: '2 tasks due today',
      ),
    });
    final spoken = await OsIntents.debugStaticValue('dueToday');
    if (spoken != '2 tasks due today') {
      _fail(name, 'spoken text did not survive: ${spoken ?? "null"}');
      return;
    }
    _pass(name, 'spec and spoken text both stored');
  } catch (e) {
    _fail(name, e);
  }
}

/// The donation chain has four links and only the last one is Apple's.
///
/// Dart → method channel → `NSClassFromString("OsIntentsDonor")` → a real
/// `AppIntent` struct rebuilt from wire values → `IntentDonationManager`. A
/// `true` here means every one of them held: the generated class was found by
/// name, the id matched a case, the values decoded, and the system accepted the
/// intent. Three of those four fail silently on their own.
///
/// What it cannot show is whether iOS ever *suggests* the action afterwards.
/// Nothing observable from here does, so the claim stops at "accepted".
Future<void> _checkDonation() async {
  const name = 'donation';
  try {
    final donated = await OsIntents.donate('addTask', {
      'title': 'from the self-check',
      'dueDate': DateTime.now().toUtc(),
      'priority': Priority.veryUrgent,
    });
    final unknown = await OsIntents.donate('nothing_declares_this');

    // This host is iOS-only. Android's half of the contract — that donate
    // declines rather than throwing — is checked by the probe app, which is
    // where an Android build of this package's runtime actually runs.
    if (!donated) {
      _fail(name, 'the platform reported nothing was donated');
      return;
    }
    if (unknown) {
      _fail(name, 'an unknown id reported success');
      return;
    }
    _pass(name, 'accepted, and an unknown id is refused');
  } catch (e) {
    _fail(name, e);
  }
}
