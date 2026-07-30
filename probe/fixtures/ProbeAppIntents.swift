import AppIntents
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// RISK #1 PROBE — do App Intents declared inside a Flutter plugin module reach
// the app's Metadata.appintents?
//
// This decides the whole architecture of os_intents:
//
//   • If YES  → the generator can emit Swift straight into the plugin's
//               Sources/ directory. `pub get` is the entire install step and
//               the user never opens Xcode.
//   • If NO   → the generator must write into the app's Runner target and the
//               CLI has to patch project.pbxproj — workable, but far more
//               fragile across Xcode versions.
//
// The intent below is deliberately NOT referenced from the app target. The only
// thing that can pull it in is App Intents metadata extraction itself.
// ─────────────────────────────────────────────────────────────────────────────

@available(iOS 16.0, *)
public struct ProbePodIntent: AppIntent {
  public static let title: LocalizedStringResource = "Probe Pod Intent"
  public static let description = IntentDescription(
    "Declared inside the os_intents_ios plugin module."
  )

  // The whole point of App Intents: run without bringing up the UI.
  public static let openAppWhenRun = false

  public init() {}

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    return .result(dialog: "ProbePodIntent ran from inside the plugin module.")
  }
}

/// Lets an app opt into the intents this module vends.
///
/// Apple's mechanism for surfacing intents that live in a framework or Swift
/// package: the app declares its own `AppIntentsPackage` and lists this type in
/// `includedPackages`. Whether it is *required* for a Flutter plugin module is
/// exactly what variants A and B measure.
/// Note the availability: `AppIntent` is iOS 16, but `AppIntentsPackage` is
/// iOS 17. Worth knowing before designing around the bridge — it cannot be the
/// baseline mechanism for an iOS 16 deployment target.
@available(iOS 17.0, *)
public struct OsIntentsPackage: AppIntentsPackage {
  public init() {}
}

// ─────────────────────────────────────────────────────────────────────────────
// RISK #1b PROBE — can the AppShortcutsProvider live here too?
//
// Risk #1 established that intents declared in this module are discoverable.
// Spoken "Hey Siri …" phrases are a separate mechanism: they come from an
// AppShortcutsProvider and land in Metadata.appintents/root.ssu.yaml. Apple
// documents at most one provider per app, which makes this the likely place
// where Plan A breaks down.
//
//   • If the phrases below reach root.ssu.yaml → Plan A covers everything and
//     os_intents_cli never has to touch the Runner target.
//   • If they do not → the generator must emit exactly one provider file into
//     the app target, and the CLI has to place it.
// ─────────────────────────────────────────────────────────────────────────────

@available(iOS 16.0, *)
public struct ProbePodShortcuts: AppShortcutsProvider {
  public static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ProbePodIntent(),
      phrases: ["Run pod probe in \(.applicationName)"],
      shortTitle: "Pod probe",
      systemImageName: "shippingbox"
    )
  }
}
