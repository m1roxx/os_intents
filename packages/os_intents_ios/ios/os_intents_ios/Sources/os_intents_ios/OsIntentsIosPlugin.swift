// Flutter ships as two differently-named frameworks — `Flutter` on iOS,
// `FlutterMacOS` on macOS — with the same API. Every file here that talks to
// the engine carries this, which is the standard shape for a plugin that serves
// both and the only difference between them in this package.
//
// `@preconcurrency`: Flutter is an Objective-C framework, so none of its types
// carry Sendability annotations and every one reads as non-Sendable to Swift
// concurrency. It says "this module predates the checking" rather than
// silencing anything of ours.
#if canImport(FlutterMacOS)
@preconcurrency import FlutterMacOS
#else
@preconcurrency import Flutter
#endif
import Foundation

public class OsIntentsIosPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    // `messenger` is a property on macOS and a method on iOS. One of the two
    // places the frameworks differ in shape rather than only in name.
    #if os(macOS)
    let messenger = registrar.messenger
    #else
    let messenger = registrar.messenger()
    #endif
    let channel = FlutterMethodChannel(
      name: "dev.osintents/bridge",
      binaryMessenger: messenger
    )
    let instance = OsIntentsIosPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    OsIntentsBridge.shared.attach(channel: channel)
    configureBackgroundEngine()
  }

  /// Hands the background engine the two things only the app target can supply:
  /// the Dart library to start, and `GeneratedPluginRegistrant`.
  ///
  /// Both live in generated code inside the Runner target, which a package
  /// cannot import. Looking the class up by its ObjC name keeps this automatic
  /// — the alternative is asking every user to paste a line into AppDelegate,
  /// which is exactly the kind of manual step this package exists to remove.
  private static func configureBackgroundEngine() {
    let selector = Selector(("configure"))
    guard let cls = NSClassFromString("OsIntentsBackgroundSetup") as? NSObject.Type,
          cls.responds(to: selector)
    else {
      // Nothing generated needs the background engine. Foreground intents are
      // unaffected, so this is not a problem worth logging loudly.
      return
    }
    _ = (cls as AnyObject).perform(selector)
  }

  /// The generated donor, looked up once by its ObjC name.
  ///
  /// Same trick as `configureBackgroundEngine`, and stored rather than resolved
  /// per call — `NSClassFromString` walks the runtime's class list, and a
  /// donation happens on a path the user is waiting on.
  ///
  /// `nonisolated(unsafe)`: written once, on the first donation, from the
  /// platform thread that every method call arrives on.
  private nonisolated(unsafe) static var cachedDonor: OsIntentsDonating?
  private nonisolated(unsafe) static var lookedUpDonor = false

  private static var donor: OsIntentsDonating? {
    if lookedUpDonor { return cachedDonor }
    lookedUpDonor = true
    guard let cls = NSClassFromString("OsIntentsDonor") as? NSObject.Type else {
      return nil
    }
    cachedDonor = cls.init() as? OsIntentsDonating
    return cachedDonor
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "ready":
      OsIntentsBridge.shared.markReady()
      result(nil)
    case "publishStatic":
      OsIntentsBridge.shared.publishStatic(call.arguments as? [String: Any] ?? [:])
      result(nil)

    case "donate":
      let args = call.arguments as? [String: Any] ?? [:]
      guard let donor = Self.donor else {
        // Nothing generated to donate, or a build that predates it. Not an
        // error: Dart is told nothing happened and carries on.
        result(false)
        return
      }
      donor.donate(
        id: args["id"] as? String ?? "",
        wire: args["args"] as? [String: Any] ?? [:]
      ) { donated in
        result(donated)
      }

    case "debugStaticValue":
      // Reads back exactly what a generated Execution.static_ intent would see.
      let id = (call.arguments as? [String: Any])?["id"] as? String ?? ""
      result(OsIntentsBridge.shared.staticValue(for: id))

    case "debugInvokeBackground":
      // Forces the headless engine even though the UI engine is alive, which
      // the normal router would never do. Exists because the alternative way to
      // exercise this path is to get iOS to background-launch the app from
      // Siri — not something a test can arrange.
      let args = call.arguments as? [String: Any] ?? [:]
      let id = args["id"] as? String ?? ""
      let params = args["args"] as? [String: Any] ?? [:]
      Task {
        do {
          let outcome = try await OsIntentsBackgroundEngine.shared.invoke(
            id: id, args: params
          )
          result(["kind": outcome.kind, "spoken": outcome.spoken as Any])
        } catch {
          result(FlutterError(
            code: "background_failed",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
