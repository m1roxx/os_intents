#!/usr/bin/env bash
#
# RISK #1 PROBE
#
# Question: does App Intents metadata extraction see intents declared inside a
# Flutter plugin module, or only ones compiled into the app's Runner target?
#
# Two builds of the same app:
#   A — no AppIntentsPackage bridge in Runner
#   B — Runner declares an AppIntentsPackage listing the plugin's
#
# In both, ProbeRunnerIntent (Runner target) is the control and must appear.
# The verdict hinges on whether ProbePodIntent (plugin module) shows up in
# Metadata.appintents/extract.actionsdata, and in which of the two builds.
#
set -uo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER="${FLUTTER_BIN:-/Users/dev/fvm/versions/3.44.8/bin/flutter}"
XCCONFIG="$APP_DIR/ios/Flutter/Debug.xcconfig"
XCCONFIG_BACKUP="$APP_DIR/ios/Flutter/Debug.xcconfig.probe-backup"
APP_BUNDLE="$APP_DIR/build/ios/iphonesimulator/Runner.app"
RESULTS="$APP_DIR/probe-results"

POD_INTENT="ProbePodIntent"
RUNNER_INTENT="ProbeRunnerIntent"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { printf '\n\033[1;34m▶ %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m%s\033[0m\n' "$1"; }

# The probe intent must be compiled INSIDE the plugin module — that is the whole
# experiment. It is not part of the published package, so it is copied in for the
# run and removed afterwards; otherwise every consumer app would ship a stray
# "Probe Pod Intent" in its Shortcuts list.
FIXTURE="$APP_DIR/../fixtures/ProbeAppIntents.swift"
PLUGIN_SRC="$APP_DIR/../../packages/os_intents_ios/ios/os_intents_ios/Sources/os_intents_ios/ProbeAppIntents.swift"

install_fixture() { cp "$FIXTURE" "$PLUGIN_SRC"; }
remove_fixture() { rm -f "$PLUGIN_SRC"; }

restore_xcconfig() {
  if [[ -f "$XCCONFIG_BACKUP" ]]; then
    mv "$XCCONFIG_BACKUP" "$XCCONFIG"
  fi
}
cleanup() { restore_xcconfig; remove_fixture; }
trap cleanup EXIT

set_bridge() {
  # $1 = on|off
  [[ -f "$XCCONFIG_BACKUP" ]] || cp "$XCCONFIG" "$XCCONFIG_BACKUP"
  if [[ "$1" == "on" ]]; then
    cat > "$XCCONFIG" <<'EOF'
#include "Generated.xcconfig"
OTHER_SWIFT_FLAGS = $(inherited) -D OS_INTENTS_BRIDGE
EOF
  else
    cat > "$XCCONFIG" <<'EOF'
#include "Generated.xcconfig"
EOF
  fi
}

build() {
  # $1 = label. Returns non-zero on build failure — the caller MUST distinguish
  # "built, intent absent" from "never built", or the verdict is a fiction.
  local label="$1"
  step "Building variant $label (simulator, debug)"
  rm -rf "$APP_BUNDLE"
  ( cd "$APP_DIR" && "$FLUTTER" build ios --simulator --debug --no-codesign ) \
    > "$RESULTS/build-$label.log" 2>&1
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "  build failed (rc=$rc)"
    grep -E "error:|Swift Compiler Error|Failed to build" "$RESULTS/build-$label.log" \
      | head -5 | sed 's/^/    /'
    echo "    full log: $RESULTS/build-$label.log"
    return 1
  fi
  echo "  ok"
  return 0
}

# Records where Metadata.appintents lives and which intents it actually names.
inspect() {
  local label="$1"
  local out="$RESULTS/metadata-$label.txt"
  : > "$out"

  # Keep the real metadata for later reading; the next build wipes the bundle.
  local archive="$RESULTS/appintents-$label"
  rm -rf "$archive"
  if [[ -d "$APP_BUNDLE/Metadata.appintents" ]]; then
    cp -R "$APP_BUNDLE/Metadata.appintents" "$archive"
  fi

  {
    echo "# Metadata.appintents bundles in Runner.app"
    find "$APP_BUNDLE" -name 'Metadata.appintents' -type d 2>/dev/null \
      | sed "s|$APP_BUNDLE|Runner.app|;s/^/    /"

    echo
    echo "# Decisive check — names inside extract.actionsdata"
    local data="$APP_BUNDLE/Metadata.appintents/extract.actionsdata"
    for name in "$POD_INTENT" "$RUNNER_INTENT"; do
      if [[ -f "$data" ]] && grep -qa "$name" "$data"; then
        echo "## $name: IN_METADATA"
      else
        echo "## $name: not-in-metadata"
      fi
    done

    echo
    echo "# Context — every file in the bundle mentioning each name"
    echo "# (a hit in Runner.debug.dylib or kernel_blob.bin proves nothing:"
    echo "#  Swift symbols and Dart string literals both land there)"
    for name in "$POD_INTENT" "$RUNNER_INTENT"; do
      echo "## $name"
      grep -rla "$name" "$APP_BUNDLE" 2>/dev/null \
        | sed "s|$APP_BUNDLE|Runner.app|;s/^/    /" || echo "    (none)"
    done
  } >> "$out"

  sed -n '/# Decisive check/,/# Context/p' "$out"
}

in_metadata() {
  # $1 = label, $2 = intent name
  grep -q "^## $2: IN_METADATA" "$RESULTS/metadata-$1.txt" 2>/dev/null
}

mkdir -p "$RESULTS"
install_fixture

bold "os_intents — Risk #1 probe"
echo "Flutter: $("$FLUTTER" --version 2>/dev/null | head -1)"
echo "Xcode:   $(xcodebuild -version 2>/dev/null | head -1)"

step "Resolving packages"
if ! ( cd "$APP_DIR" && "$FLUTTER" pub get ) > "$RESULTS/pub-get.log" 2>&1; then
  fail "pub get failed — see $RESULTS/pub-get.log"
  tail -20 "$RESULTS/pub-get.log"
  exit 1
fi
echo "  ok"

built_a=false
built_b=false

set_bridge off
if build "A"; then
  built_a=true
  step "Variant A — plugin-module intent, no AppIntentsPackage bridge"
  inspect "A"
fi

set_bridge on
if build "B"; then
  built_b=true
  step "Variant B — Runner declares AppIntentsPackage{ includedPackages: [OsIntentsPackage] }"
  inspect "B"
fi

restore_xcconfig

# ── Verdict ──────────────────────────────────────────────────────────────────
step "VERDICT"

if [[ "$built_a" != true && "$built_b" != true ]]; then
  fail "INCONCLUSIVE — neither variant built. Nothing was measured."
  exit 2
fi

if ! { in_metadata "A" "$RUNNER_INTENT" || in_metadata "B" "$RUNNER_INTENT"; }; then
  fail "INCONCLUSIVE — the control intent never reached the metadata either."
  echo "The probe is broken, not the architecture. Fix it before concluding"
  echo "anything about plugin-module intents."
  exit 2
fi

echo "control   ($RUNNER_INTENT, Runner target): in metadata ✓"

report() {
  # $1 = label, $2 = built flag
  printf 'variant %s (%s, plugin module): ' "$1" "$POD_INTENT"
  if [[ "$2" != true ]]; then
    printf '\033[1;33mBUILD FAILED — inconclusive\033[0m\n'
  elif in_metadata "$1" "$POD_INTENT"; then
    echo "in metadata ✓"
  else
    echo "absent ✗"
  fi
}
report "A" "$built_a"
report "B" "$built_b"

echo
if [[ "$built_a" == true ]] && in_metadata "A" "$POD_INTENT"; then
  bold "→ PLAN A: generate Swift straight into the plugin module."
  echo "  Metadata extraction picks it up with no bridge and no Xcode surgery."
  echo "  'flutter pub get' is the entire install step."
elif [[ "$built_b" == true ]] && in_metadata "B" "$POD_INTENT"; then
  bold "→ PLAN A': plugin module + a generated AppIntentsPackage bridge in Runner."
  echo "  One small generated file must reach the app target. Note that"
  echo "  AppIntentsPackage is iOS 17+, so iOS 16 users would lose the feature."
elif [[ "$built_a" == true || "$built_b" == true ]]; then
  bold "→ PLAN B: generate into the app's Runner target."
  echo "  The CLI has to patch project.pbxproj — budget real time for it."
else
  fail "No conclusion: every variant that mattered failed to build."
  exit 2
fi

echo
echo "Artifacts: $RESULTS (metadata-*.txt, appintents-*/, build-*.log)"
