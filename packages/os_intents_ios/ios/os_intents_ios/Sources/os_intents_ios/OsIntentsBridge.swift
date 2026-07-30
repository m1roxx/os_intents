import Flutter
import Foundation

/// What a Dart handler answered with.
public struct IntentOutcome {
  public let kind: String
  public let spoken: String?
  public let value: Any?

  init(wire: [String: Any]) {
    kind = wire["kind"] as? String ?? "done"
    spoken = wire["spoken"] as? String ?? wire["displayed"] as? String
    value = wire["value"]
  }
}

public enum OsIntentsError: Error, LocalizedError {
  case engineUnavailable
  case timedOut
  case handlerFailed(String)

  public var errorDescription: String? {
    switch self {
    case .engineUnavailable:
      return "The Flutter engine was not available to run this action."
    case .timedOut:
      return "The action took too long to complete."
    case .handlerFailed(let message):
      return message
    }
  }
}

/// The single point every generated `AppIntent` struct calls into.
///
/// Generated Swift never touches Flutter APIs directly — it only knows
/// `OsIntentsBridge.shared.invoke(id:args:)`. That keeps codegen output stable
/// across Flutter releases.
public final class OsIntentsBridge: @unchecked Sendable {
  public static let shared = OsIntentsBridge()

  private let lock = NSLock()
  private var channel: FlutterMethodChannel?
  private var isReady = false
  private var readyWaiters: [CheckedContinuation<Void, Never>] = []

  /// How long to wait for Dart handlers to register during a cold launch that
  /// was itself triggered by an intent.
  public var readyTimeout: TimeInterval = 8

  private init() {}

  // MARK: - Wiring, called by the plugin registrar

  /// Set while `GeneratedPluginRegistrant` runs against the background engine.
  ///
  /// That registrant registers *every* plugin, including this one, so without
  /// the guard the background engine's channel would replace the UI engine's
  /// here — and every foreground invocation would then be delivered to the
  /// wrong isolate.
  public static var isRegisteringBackgroundEngine = false

  func attach(channel: FlutterMethodChannel) {
    if Self.isRegisteringBackgroundEngine { return }
    lock.lock()
    self.channel = channel
    lock.unlock()
  }

  func markReady() {
    lock.lock()
    isReady = true
    let waiters = readyWaiters
    readyWaiters.removeAll()
    lock.unlock()
    waiters.forEach { $0.resume() }
  }

  func publishStatic(_ values: [String: Any]) {
    Self.staticStore.set(values, forKey: Self.staticKey)
  }

  /// Where `Execution.static_` answers are kept.
  ///
  /// Plain `UserDefaults`, deliberately. Generated intents are compiled into
  /// the app target, so `perform()` runs in the app's own process — an App
  /// Group would buy nothing here. It becomes necessary only if intents ever
  /// move into a separate App Intents extension, and then this is the one place
  /// to change.
  ///
  /// The first version of this shipped writing to an App Group that was never
  /// provisioned (`UserDefaults(suiteName:)` returned nil, so the write was
  /// dropped) while reading back from `.standard`. The two never met.
  public static var staticStore: UserDefaults = .standard

  static let staticKey = "os_intents.static"

  // MARK: - Called from generated AppIntent.perform()

  /// Runs a handler without showing the app.
  ///
  /// Prefers the UI engine when the app is already running: reusing the live
  /// isolate keeps the user's in-memory state visible to the handler, and a
  /// second isolate would see a different, empty world. Only when there is no
  /// UI engine — which is the case for a background launch — does this spin up
  /// the headless one.
  public func invokeBackground(
    id: String, args: [String: Any?]
  ) async throws -> IntentOutcome {
    lock.lock()
    let uiReady = isReady && channel != nil
    lock.unlock()

    if uiReady {
      return try await invoke(id: id, args: args)
    }
    return try await OsIntentsBackgroundEngine.shared.invoke(id: id, args: args)
  }

  public func invoke(id: String, args: [String: Any?]) async throws -> IntentOutcome {
    try await waitUntilReady()

    lock.lock()
    let channel = self.channel
    lock.unlock()

    guard let channel else { throw OsIntentsError.engineUnavailable }

    let payload: [String: Any] = [
      "id": id,
      "args": args.compactMapValues { $0 },
    ]

    let wire: [String: Any] = try await withCheckedThrowingContinuation { cont in
      DispatchQueue.main.async {
        channel.invokeMethod("invoke", arguments: payload) { response in
          if let error = response as? FlutterError {
            cont.resume(throwing: OsIntentsError.handlerFailed(
              error.message ?? error.code
            ))
          } else if let map = response as? [String: Any] {
            cont.resume(returning: map)
          } else {
            cont.resume(returning: ["kind": "done"])
          }
        }
      }
    }

    if wire["kind"] as? String == "error" {
      throw OsIntentsError.handlerFailed(wire["message"] as? String ?? "unknown")
    }
    return IntentOutcome(wire: wire)
  }

  /// Reads a value published by `publishStaticValues` for an
  /// `Execution.static_` intent.
  ///
  /// Deliberately synchronous and engine-free: this path exists precisely so a
  /// read-only action costs nothing and cannot be evicted for memory.
  public func staticValue(for id: String) -> String? {
    let values = Self.staticStore.dictionary(forKey: Self.staticKey)
    return values?[id] as? String
  }

  // MARK: - Entity resolution, called from generated EntityStringQuery types

  public func resolveEntities(
    type: String, ids: [String]
  ) async throws -> [[String: Any]] {
    try await entityCall("entities.byIds", ["type": type, "ids": ids])
  }

  public func searchEntities(
    type: String, query: String
  ) async throws -> [[String: Any]] {
    try await entityCall("entities.matching", ["type": type, "query": query])
  }

  public func suggestedEntities(type: String) async throws -> [[String: Any]] {
    try await entityCall("entities.suggested", ["type": type])
  }

  private func entityCall(
    _ method: String, _ payload: [String: Any]
  ) async throws -> [[String: Any]] {
    try await waitUntilReady()

    lock.lock()
    let channel = self.channel
    lock.unlock()
    guard let channel else { throw OsIntentsError.engineUnavailable }

    return try await withCheckedThrowingContinuation { cont in
      DispatchQueue.main.async {
        channel.invokeMethod(method, arguments: payload) { response in
          if let error = response as? FlutterError {
            cont.resume(throwing: OsIntentsError.handlerFailed(
              error.message ?? error.code
            ))
          } else if let list = response as? [[String: Any]] {
            cont.resume(returning: list)
          } else {
            // An empty list is a legitimate answer — the user simply has no
            // matching objects — so this is not an error.
            cont.resume(returning: [])
          }
        }
      }
    }
  }

  private func waitUntilReady() async throws {
    lock.lock()
    if isReady {
      lock.unlock()
      return
    }
    lock.unlock()

    // An intent can launch the app from cold. Buffer rather than drop.
    let deadline = Task {
      try await Task.sleep(nanoseconds: UInt64(readyTimeout * 1_000_000_000))
      throw OsIntentsError.timedOut
    }
    let waiter = Task { @Sendable in
      await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        lock.lock()
        if isReady {
          lock.unlock()
          cont.resume()
        } else {
          readyWaiters.append(cont)
          lock.unlock()
        }
      }
    }
    defer { deadline.cancel() }
    await waiter.value
  }
}
