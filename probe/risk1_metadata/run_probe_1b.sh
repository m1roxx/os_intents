#!/usr/bin/env bash
#
# RISK #1b PROBE — where may the AppShortcutsProvider live?
#
# Risk #1 settled discoverability: intents declared inside a Flutter plugin
# module reach Metadata.appintents on their own. Spoken Siri phrases are a
# different mechanism — they come from an AppShortcutsProvider and land in
# Metadata.appintents/root.ssu.yaml. Apple documents at most one provider per
# app, so this is the likely place Plan A breaks.
#
# The plugin module always declares ProbePodShortcuts ("Run pod probe in <app>").
# The Runner's own provider is gated by -D PROBE_RUNNER_SHORTCUTS.
#
#   Variant P (plugin-only)  — no flag. The app has no provider of its own, so
#                              anything in root.ssu.yaml came from the plugin.
#   Variant D (dual)         — flag on. Both providers exist, which is what a
#                              real app that already ships shortcuts looks like.
#
set -uo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER="${FLUTTER_BIN:-/Users/dev/fvm/versions/3.44.8/bin/flutter}"
XCCONFIG="$APP_DIR/ios/Flutter/Debug.xcconfig"
XCCONFIG_BACKUP="$APP_DIR/ios/Flutter/Debug.xcconfig.probe1b-backup"
APP_BUNDLE="$APP_DIR/build/ios/iphonesimulator/Runner.app"
RESULTS="$APP_DIR/probe-results-1b"

POD_UTTERANCE="Run pod probe"
RUNNER_UTTERANCE="Run runner probe"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { printf '\n\033[1;34m▶ %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m%s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$1"; }

# The probe intent must be compiled INSIDE the plugin module — that is the whole
# experiment. It is not part of the published package, so it is copied in for the
# run and removed afterwards; otherwise every consumer app would ship a stray
# "Probe Pod Intent" in its Shortcuts list.
FIXTURE="$APP_DIR/../fixtures/ProbeAppIntents.swift"
PLUGIN_SRC="$APP_DIR/../../packages/os_intents_ios/ios/os_intents_ios/Sources/os_intents_ios/ProbeAppIntents.swift"

install_fixture() { cp "$FIXTURE" "$PLUGIN_SRC"; }
remove_fixture() { rm -f "$PLUGIN_SRC"; }

restore_xcconfig() {
  [[ -f "$XCCONFIG_BACKUP" ]] && mv "$XCCONFIG_BACKUP" "$XCCONFIG"
}
cleanup() { restore_xcconfig; remove_fixture; }
trap cleanup EXIT

set_runner_provider() {
  [[ -f "$XCCONFIG_BACKUP" ]] || cp "$XCCONFIG" "$XCCONFIG_BACKUP"
  if [[ "$1" == "on" ]]; then
    cat > "$XCCONFIG" <<'EOF'
#include "Generated.xcconfig"
OTHER_SWIFT_FLAGS = $(inherited) -D PROBE_RUNNER_SHORTCUTS
EOF
  else
    cat > "$XCCONFIG" <<'EOF'
#include "Generated.xcconfig"
EOF
  fi
}

build() {
  local label="$1"
  step "Building variant $label"
  rm -rf "$APP_BUNDLE"
  ( cd "$APP_DIR" && "$FLUTTER" build ios --simulator --debug --no-codesign ) \
    > "$RESULTS/build-$label.log" 2>&1
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "  build failed (rc=$rc)"
    grep -E "error:|Swift Compiler Error|Failed to build" "$RESULTS/build-$label.log" \
      | head -6 | sed 's/^/    /'
    echo "    full log: $RESULTS/build-$label.log"
    return 1
  fi
  echo "  ok"
  return 0
}

inspect() {
  local label="$1"
  local out="$RESULTS/ssu-$label.txt"
  local meta="$APP_BUNDLE/Metadata.appintents"
  local archive="$RESULTS/appintents-$label"

  rm -rf "$archive"
  [[ -d "$meta" ]] && cp -R "$meta" "$archive"

  : > "$out"
  {
    if [[ ! -f "$meta/root.ssu.yaml" ]]; then
      echo "## root.ssu.yaml: MISSING"
    else
      echo "## root.ssu.yaml: present"
      for u in "$POD_UTTERANCE" "$RUNNER_UTTERANCE"; do
        if grep -qa "$u" "$meta/root.ssu.yaml"; then
          echo "### utterance \"$u\": PRESENT"
        else
          echo "### utterance \"$u\": absent"
        fi
      done
    fi

    # Names the provider the extractor actually selected for the app.
    if [[ -f "$meta/extract.actionsdata" ]]; then
      local prov
      prov=$(python3 -c "
import json,sys
d=json.load(open('$meta/extract.actionsdata'))
print(d.get('autoShortcutProviderMangledName') or '(none)')
print('autoShortcuts:', json.dumps(d.get('autoShortcuts'))[:300])
" 2>/dev/null)
      echo "## autoShortcutProviderMangledName / autoShortcuts:"
      echo "$prov" | sed 's/^/    /'
    fi
  } >> "$out"

  cat "$out"
}

has_utterance() {
  # $1 = label, $2 = utterance
  grep -qa "^### utterance \"$2\": PRESENT" "$RESULTS/ssu-$1.txt" 2>/dev/null
}

mkdir -p "$RESULTS"
install_fixture

bold "os_intents — Risk #1b probe (AppShortcutsProvider placement)"
echo "Flutter: $("$FLUTTER" --version 2>/dev/null | head -1)"
echo "Xcode:   $(xcodebuild -version 2>/dev/null | head -1)"

built_p=false
built_d=false

set_runner_provider off
if build "P (plugin provider only)"; then built_p=true; fi
[[ "$built_p" == true ]] && { step "Variant P — only the plugin module declares a provider"; inspect "P"; }

set_runner_provider on
if build "D (both providers)"; then built_d=true; fi
[[ "$built_d" == true ]] && { step "Variant D — plugin and Runner both declare a provider"; inspect "D"; }

restore_xcconfig

step "VERDICT"

if [[ "$built_p" != true ]]; then
  fail "Variant P did not build — the decisive case was never measured."
  grep -E "error:" "$RESULTS/build-P (plugin provider only).log" 2>/dev/null | head -5
  exit 2
fi

printf 'variant P — plugin phrases in root.ssu.yaml: '
has_utterance "P" "$POD_UTTERANCE" && echo "PRESENT ✓" || echo "absent ✗"

if [[ "$built_d" == true ]]; then
  printf 'variant D — plugin phrases, app also has a provider: '
  has_utterance "D" "$POD_UTTERANCE" && echo "PRESENT ✓" || echo "absent ✗"
  printf 'variant D — app phrases: '
  has_utterance "D" "$RUNNER_UTTERANCE" && echo "PRESENT ✓" || echo "absent ✗"
else
  warn "variant D did not build — see the log; two providers may be a hard conflict."
fi

echo
if has_utterance "P" "$POD_UTTERANCE"; then
  if [[ "$built_d" == true ]] && has_utterance "D" "$POD_UTTERANCE" && has_utterance "D" "$RUNNER_UTTERANCE"; then
    bold "→ PLAN A COMPLETE: the provider may live in the plugin, and coexists"
    echo "  with an app-owned one. Nothing ever needs to reach the Runner target."
  elif [[ "$built_d" == true ]]; then
    bold "→ PLAN A WITH A CAVEAT: a plugin-declared provider works on its own, but"
    echo "  loses or is lost when the app declares one too. The generator must"
    echo "  detect an existing provider and merge into it instead."
  else
    bold "→ PLAN A (single-provider only): works when the app has no provider;"
    echo "  two providers fail to build. Merging is mandatory."
  fi
else
  bold "→ PHRASES NEED THE APP TARGET."
  echo "  Intents still come free from the plugin module (Risk #1), but the"
  echo "  generator must emit one AppShortcutsProvider into Runner and the CLI"
  echo "  has to place it. Much smaller than Plan B, but not zero."
fi

echo
echo "Artifacts: $RESULTS"
