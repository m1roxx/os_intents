#!/usr/bin/env bash
#
# Wires os_intents into a throwaway app made by `flutter create` and checks that
# one command carries it all the way to a build.
#
# What this catches that nothing else does: the workspace. Every other check
# here runs inside it, where the six packages resolve each other locally and a
# missing dependency is invisible — that has already hidden one omission. A
# stranger has none of that, and this is the closest thing to being one.
#
# The Android build is the point of the manifest half: aapt rejects a
# <meta-data> pointing at a resource it cannot find, so an APK that builds is
# the proof that `install` wrote something real.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-${TMPDIR:-/tmp}/os_intents_cold_start}"

# Flutter is pinned per-repo in .fvmrc, and the throwaway project has no .fvmrc
# of its own — so `fvm flutter` inside it would silently fall back to whatever
# global SDK the machine has. Resolve the pinned one by path instead.
sdk() {
  local tool="$1" env_override="$2"
  if [ -n "$env_override" ]; then printf '%s' "$env_override"; return; fi
  if [ -x "$ROOT/.fvm/flutter_sdk/bin/$tool" ]; then
    printf '%s' "$ROOT/.fvm/flutter_sdk/bin/$tool"
  else
    command -v "$tool" || true
  fi
}
FLUTTER="$(sdk flutter "${FLUTTER_BIN:-}")"
DART="$(sdk dart "${DART_BIN:-}")"
if [ ! -x "$FLUTTER" ] || [ ! -x "$DART" ]; then
  echo "No Flutter SDK. Run 'fvm install' in $ROOT, or set FLUTTER_BIN/DART_BIN." >&2
  exit 1
fi

step() { printf '\n=== %s\n' "$1"; }
fail() { printf '\nFAILED: %s\n' "$1" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$(dirname "$WORK")"

step "flutter create"
"$FLUTTER" create --platforms=android,ios --org dev.osintents \
  "$WORK" >/dev/null || fail "flutter create"

step "depend on os_intents"
# Overrides rather than path dependencies: the six packages carry
# `resolution: workspace`, and this project is a member of nothing. That is the
# situation a real consumer is in once they come from pub.dev.
cat > "$WORK/pubspec.yaml" <<EOF
name: cold_start
description: "Cold-start check for os_intents."
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ^3.12.2

dependencies:
  flutter:
    sdk: flutter
  os_intents: any

dev_dependencies:
  build_runner: ^2.4.13
  os_intents_gen: any
  os_intents_cli: any

dependency_overrides:
  os_intents: {path: $ROOT/packages/os_intents}
  os_intents_gen: {path: $ROOT/packages/os_intents_gen}
  os_intents_cli: {path: $ROOT/packages/os_intents_cli}
  os_intents_ios: {path: $ROOT/packages/os_intents_ios}
  os_intents_android: {path: $ROOT/packages/os_intents_android}
  os_intents_platform_interface: {path: $ROOT/packages/os_intents_platform_interface}

flutter:
  uses-material-design: true
EOF

cat > "$WORK/lib/intents.dart" <<'EOF'
import 'package:os_intents/os_intents.dart';

part 'intents.os_intents.g.dart';

@AppIntent(
  title: 'Add task',
  description: 'Creates a new task in the Inbox',
  phrases: [r'Add a task to $app'],
  systemImageName: 'plus.circle',
  execution: Execution.background,
)
Future<IntentResult> addTask({
  @Param(title: 'Title', requestValueDialog: 'What should it be called?')
  required String title,
  @Param(title: 'Priority') Priority? priority,
}) async => IntentResult.dialog('Added "$title"');

@AppEnum(typeName: 'Priority', displayName: 'Priority')
enum Priority { whenever, urgent }

@AppIntent(
  title: 'Open inbox',
  description: 'Shows the inbox',
  phrases: [r'Open my $app inbox'],
)
Future<IntentResult> openInbox() async => IntentResult.done();
EOF

cat > "$WORK/lib/main.dart" <<'EOF'
import 'package:flutter/material.dart';
import 'package:os_intents/os_intents.dart';

import 'intents.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await OsIntents.install($osIntentsRegistry);
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('cold')))));
}
EOF

cd "$WORK" || fail "cd $WORK"
"$FLUTTER" pub get >/dev/null || fail "pub get from outside the workspace"

step "os_intents build"
"$DART" run os_intents_cli:os_intents build || fail "build"

step "everything is registered"
# Idempotent by construction, so a second run must be a no-op — and --check is
# the CI-facing half of the same question.
"$DART" run os_intents_cli:os_intents install --check || fail "install --check"

grep -q 'android.app.shortcuts' android/app/src/main/AndroidManifest.xml \
  || fail "the launcher activity was not pointed at the generated shortcuts"
grep -q 'OsIntentsGenerated.swift in Sources' ios/Runner.xcodeproj/project.pbxproj \
  || fail "the generated Swift is in no build phase"

step "flutter build apk --debug"
# aapt fails outright on a <meta-data> naming a resource that is not there, so
# this is what proves the manifest edit is real rather than merely well-formed.
"$FLUTTER" build apk --debug || fail "android build"

if [ "$(uname)" = "Darwin" ] && [ "${SKIP_IOS:-}" != "1" ]; then
  step "flutter build ios --simulator --debug"
  "$FLUTTER" build ios --simulator --debug || fail "ios build"

  step "os_intents doctor"
  "$DART" run os_intents_cli:os_intents doctor || fail "doctor"
fi

printf '\nOK — a blank flutter create reaches a built app in one command.\n'
printf 'Project left at %s\n' "$WORK"
