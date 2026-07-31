#!/usr/bin/env bash
#
# Runs the example app's self-check on a booted simulator and reports what the
# device actually did.
#
# Why not `flutter test`: every claim here — the headless engine, the static
# store, the entity channel — only exists on a device. And not through the UI
# either: injected taps do not reach Flutter's gesture layer on this setup, so
# the checks run from main() behind a --dart-define instead.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/packages/os_intents/example"

# Flutter is pinned per-repo in .fvmrc, so the SDK fvm linked into .fvm/ is the
# one every other step here used. Fall back to PATH for a machine without fvm,
# and let FLUTTER_BIN/DART_BIN override either.
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
  printf 'No Flutter SDK. Run `fvm install` in the repo root, or set FLUTTER_BIN and DART_BIN.\n' >&2
  exit 1
fi
BUNDLE_ID="dev.osintents.osIntentsExample"
RESULTS="$ROOT/probe/integration-results"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { printf '\n\033[1;34m▶ %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m%s\033[0m\n' "$1"; }

mkdir -p "$RESULTS"

DEVICE="${1:-$(xcrun simctl list devices booted -j 2>/dev/null \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
for rt in d.values():
    for dev in rt:
        if dev.get("state")=="Booted":
            print(dev["udid"]); raise SystemExit')}"

if [[ -z "${DEVICE:-}" ]]; then
  fail "No booted simulator. Boot one, or pass a UDID as the first argument."
  exit 2
fi

bold "os_intents — integration self-check"
echo "device:  $DEVICE"
echo "flutter: $("$FLUTTER" --version 2>/dev/null | head -1)"

step "Regenerating"
if ! ( cd "$APP" && "$DART" run build_runner build --delete-conflicting-outputs ) \
      > "$RESULTS/build_runner.log" 2>&1; then
  fail "build_runner failed"; tail -20 "$RESULTS/build_runner.log"; exit 1
fi
if ! ( cd "$APP" && "$DART" run os_intents_cli:os_intents sync ) \
      > "$RESULTS/sync.log" 2>&1; then
  fail "sync failed"; tail -20 "$RESULTS/sync.log"; exit 1
fi
if ! ( cd "$APP" && "$DART" run os_intents_cli:os_intents install ) \
      > "$RESULTS/install.log" 2>&1; then
  fail "install failed"; tail -20 "$RESULTS/install.log"; exit 1
fi
echo "  ok"

step "Building"
if ! ( cd "$APP" && "$FLUTTER" build ios --simulator --debug --no-codesign \
        --dart-define=OS_INTENTS_SELFCHECK=true ) \
      > "$RESULTS/build.log" 2>&1; then
  fail "build failed"
  grep -E "error:|Failed to build" "$RESULTS/build.log" | head -10
  exit 1
fi
echo "  ok"

step "Launching"
# Local time, not UTC: `log show --start` reads it in the device's local zone,
# so a UTC stamp widens the window by the offset and sweeps in earlier runs.
START_AT=$(date +%Y-%m-%d\ %H:%M:%S)
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1
xcrun simctl install "$DEVICE" "$APP/build/ios/iphonesimulator/Runner.app" \
  > "$RESULTS/launch.log" 2>&1 || { fail "install to simulator failed"; exit 1; }
xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >> "$RESULTS/launch.log" 2>&1 \
  || { fail "launch failed"; tail -5 "$RESULTS/launch.log"; exit 1; }
echo "  ok"

step "Collecting"
# Poll rather than sleep: the checks include an engine start and finish in a
# couple of seconds, but a cold simulator can be far slower.
OUT="$RESULTS/selfcheck.txt"
for _ in $(seq 1 30); do
  xcrun simctl spawn "$DEVICE" log show --start "$START_AT" \
    --predicate 'processImagePath CONTAINS "Runner"' --style compact 2>/dev/null \
    | grep -o 'OSINTENTS_SELFCHECK.*' > "$OUT"
  grep -q "OSINTENTS_SELFCHECK END" "$OUT" && break
done

if ! grep -q "OSINTENTS_SELFCHECK END" "$OUT"; then
  fail "The self-check never finished. Raw output:"
  cat "$OUT"
  echo
  echo "If this is empty the app may have crashed before main() completed;"
  echo "see $RESULTS/launch.log and the device console."
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
