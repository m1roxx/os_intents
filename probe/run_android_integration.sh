#!/usr/bin/env bash
#
# Runs the Android probe's self-check on an emulator and reports what the device
# actually did.
#
# The counterpart of run_integration.sh. Same reasoning: the thing worth proving
# — that a second, headless FlutterEngine starts inside the app process and runs
# Dart — exists only on a device, and no test can arrange for an on-device agent
# to invoke a real AppFunction.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/probe/android_appfunctions"
FLUTTER="${FLUTTER_BIN:-/Users/dev/fvm/versions/3.44.8/bin/flutter}"
DART="${DART_BIN:-/Users/dev/fvm/versions/3.44.8/bin/dart}"
ADB="${ADB_BIN:-$HOME/Library/Android/sdk/platform-tools/adb}"
APP_ID="dev.osintents.appfunctions_probe"
RESULTS="$ROOT/probe/android-results"

# The intent the harness launches through the app-shortcuts path. Must have no
# required parameters — a shortcut tap cannot supply one, and the emitter leaves
# such intents out of the launcher for exactly that reason.
EXPECT_SHORTCUT="openInbox"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { printf '\n\033[1;34m▶ %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m%s\033[0m\n' "$1"; }

mkdir -p "$RESULTS"

if ! "$ADB" shell true >/dev/null 2>&1; then
  fail "No device reachable over adb. Boot the emulator first:"
  echo "  \$ANDROID_HOME/emulator/emulator -avd os_intents_api36 -no-window &"
  exit 2
fi

API=$("$ADB" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
bold "os_intents — Android self-check"
echo "device api: $API"
if [[ "${API:-0}" -lt 36 ]]; then
  fail "AppFunctionService is @RequiresApi(36); this device is API $API."
  exit 2
fi

step "Regenerating"
if ! ( cd "$APP" && "$DART" run build_runner build --delete-conflicting-outputs ) \
      > "$RESULTS/build_runner.log" 2>&1; then
  fail "build_runner failed"; tail -20 "$RESULTS/build_runner.log"; exit 1
fi
if ! ( cd "$APP" && "$DART" run os_intents_cli:os_intents sync --android ) \
      > "$RESULTS/sync.log" 2>&1; then
  fail "sync failed"; tail -20 "$RESULTS/sync.log"; exit 1
fi
echo "  ok"

step "Building"
if ! ( cd "$APP" && "$FLUTTER" build apk --debug \
        --dart-define=OS_INTENTS_SELFCHECK=true \
        --dart-define=OS_INTENTS_EXPECT_SHORTCUT="$EXPECT_SHORTCUT" ) \
      > "$RESULTS/build.log" 2>&1; then
  fail "build failed"
  grep -E "^e: |error:|What went wrong" "$RESULTS/build.log" | head -10
  exit 1
fi
echo "  ok"

step "Launching"
"$ADB" logcat -c 2>/dev/null
"$ADB" uninstall "$APP_ID" >/dev/null 2>&1
if ! "$ADB" install -r "$APP/build/app/outputs/flutter-apk/app-debug.apk" \
      > "$RESULTS/install.log" 2>&1; then
  fail "install failed"; tail -5 "$RESULTS/install.log"; exit 1
fi
# `am start` on the activity, not `monkey -c LAUNCHER`: an ATD image — the one
# configuration that boots headless on this machine — ships no launcher, so
# resolving a LAUNCHER category finds nothing and monkey exits -5.
#
# Started with the Intent an app shortcut builds, rather than a plain launch.
# Same reason: there is no launcher to tap the shortcut in, so the harness
# reproduces the Intent the system was measured to build from the generated
# shortcuts.xml (probe/android_shortcuts) and checks it reaches the handler.
if ! "$ADB" shell am start -n "$APP_ID/.MainActivity" \
      -a dev.osintents.action.RUN -d "osintents://intent/$EXPECT_SHORTCUT" \
      > "$RESULTS/launch.log" 2>&1; then
  fail "am start failed"; tail -5 "$RESULTS/launch.log"; exit 1
fi
if grep -qi "error" "$RESULTS/launch.log"; then
  fail "am start reported an error:"; cat "$RESULTS/launch.log"; exit 1
fi
echo "  ok"

step "Collecting"
OUT="$RESULTS/selfcheck.txt"
# Poll rather than sleep: starting a second engine on a cold emulator is far
# slower than on a warm one.
for _ in $(seq 1 40); do
  "$ADB" logcat -d 2>/dev/null | grep -o 'OSINTENTS_SELFCHECK.*' > "$OUT"
  grep -q "OSINTENTS_SELFCHECK END" "$OUT" && break
  # `adb logcat -d` returns instantly, so without this the whole loop finishes
  # before the headless engine has even started.
  sleep 2
done

if ! grep -q "OSINTENTS_SELFCHECK END" "$OUT"; then
  fail "The self-check never finished. Raw output:"
  cat "$OUT"
  echo
  echo "If this is empty the app may have died before main() completed. Try:"
  echo "  $ADB logcat -d | grep -iE 'flutter|AndroidRuntime'"
  exit 1
fi

sed 's/^OSINTENTS_SELFCHECK //' "$OUT" | grep -vE '^(BEGIN|END)$' \
  | sed 's/^PASS/  ✓/;s/^FAIL/  ✗/'

step "RESULT"
PASSED=$(grep -c "SELFCHECK PASS" "$OUT")
FAILED=$(grep -c "SELFCHECK FAIL" "$OUT")
echo "passed: $PASSED   failed: $FAILED"
echo "full output: $OUT"

[[ "$FAILED" -eq 0 ]] || exit 1
