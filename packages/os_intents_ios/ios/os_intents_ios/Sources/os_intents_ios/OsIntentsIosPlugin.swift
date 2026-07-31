// See the note in OsIntentsBridge.swift.
@preconcurrency import Flutter
import UIKit

public class OsIntentsIosPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "dev.osintents/bridge",
      binaryMessenger: registrar.messenger()
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

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "ready":
      OsIntentsBridge.shared.markReady()
      result(nil)
    case "publishStatic":
      OsIntentsBridge.shared.publishStatic(call.arguments as? [String: Any] ?? [:])
      result(nil)

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
