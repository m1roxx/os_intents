import AppIntents
import Flutter
import UIKit

// The bridge that opts the app into intents vended by the plugin module.
// Enabled by adding `-D OS_INTENTS_BRIDGE` to OTHER_SWIFT_FLAGS; run_probe.sh
// toggles it between the two builds.
#if OS_INTENTS_BRIDGE
  import os_intents_ios
#endif

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// VARIANT C — control. An intent compiled directly into the Runner target.
// This is the arrangement every existing Flutter App Intents package forces on
// its users. It must always show up; if it doesn't, the probe itself is broken.
// ─────────────────────────────────────────────────────────────────────────────

@available(iOS 16.0, *)
struct ProbeRunnerIntent: AppIntent {
  static let title: LocalizedStringResource = "Probe Runner Intent"
  static let description = IntentDescription("Declared in the Runner target.")
  static let openAppWhenRun = false

  func perform() async throws -> some IntentResult & ProvidesDialog {
    return .result(dialog: "ProbeRunnerIntent ran from the app target.")
  }
}

// Gated for probe 1b: with the flag off the app has NO provider of its own, so
// anything appearing in root.ssu.yaml can only have come from the plugin module.
// With it on, both providers exist — the case a real app already in the wild
// would present.
#if PROBE_RUNNER_SHORTCUTS
  @available(iOS 16.0, *)
  struct ProbeShortcuts: AppShortcutsProvider {
    // Only the control intent is listed. ProbePodIntent is intentionally left
    // unreferenced so that nothing but metadata extraction can pull it in.
    static var appShortcuts: [AppShortcut] {
      AppShortcut(
        intent: ProbeRunnerIntent(),
        phrases: ["Run runner probe in \(.applicationName)"],
        shortTitle: "Runner probe",
        systemImageName: "checkmark.seal"
      )
    }
  }
#endif

// ─────────────────────────────────────────────────────────────────────────────
// VARIANT B — the app declares an AppIntentsPackage that includes the plugin's.
// Present only when OS_INTENTS_BRIDGE is defined.
// ─────────────────────────────────────────────────────────────────────────────

#if OS_INTENTS_BRIDGE
  // AppIntentsPackage is iOS 17+, unlike AppIntent itself (iOS 16+).
  @available(iOS 17.0, *)
  struct ProbeAppPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
      [OsIntentsPackage.self]
    }
  }
#endif
