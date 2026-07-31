// Flutter is an Objective-C framework: none of its types carry Sendability
// annotations, so every one of them reads as non-Sendable to Swift concurrency.
// @preconcurrency says "this module predates the checking" rather than silencing
// anything of ours — os_intents' own types are checked normally.
@preconcurrency import Flutter
import Foundation

/// What a Dart handler answered with.
///
/// An unrecognised `kind` reads as `done`, so a newer app package can add one
/// without breaking an app built against this version of the plugin.
public struct IntentOutcome {
  public let kind: String
  public let spoken: String?

  /// Wire form of a `SnippetSpec`, when the handler returned one.
  public let snippet: [String: Any]?

  /// What `IntentResult.value` carried, still in wire form.
  ///
  /// Read through the typed accessors rather than directly: the method channel
  /// decodes numbers as `NSNumber`, so `as? Int` on a value Dart sent as a
  /// double succeeds and silently truncates.
  public let value: Any?

  public init(wire: [String: Any]) {
    kind = wire["kind"] as? String ?? "done"
    spoken = wire["spoken"] as? String ?? wire["displayed"] as? String
    snippet = wire["spec"] as? [String: Any]
    value = wire["value"]
  }

  public var stringValue: String? { value as? String }
  public var boolValue: Bool? { (value as? NSNumber)?.boolValue }
  public var intValue: Int? { (value as? NSNumber)?.intValue }
  public var doubleValue: Double? { (value as? NSNumber)?.doubleValue }

  /// `DateTime` crosses as epoch milliseconds, UTC — the same shape a
  /// parameter takes in the other direction.
  public var dateValue: Date? {
    guard let ms = (value as? NSNumber)?.doubleValue else { return nil }
    return Date(timeIntervalSince1970: ms / 1000)
  }
}

/// A continuation several racers may try to resume, of which exactly one wins.
///
/// Every timeout here guards something that answers by callback — a Flutter
/// method-channel reply, or Dart reporting its handlers registered — and a
/// checked continuation must be resumed exactly once, never twice. The obvious
/// shape, a task group racing the work against a sleep, is the wrong one: a
/// group awaits its children on the way out and a checked continuation ignores
/// cancellation, so the loser stays suspended and hangs the very path that was
/// supposed to report the timeout.
final class OneShotContinuation<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?

  init(_ continuation: CheckedContinuation<T, Error>) {
    self.continuation = continuation
  }

  func resume(returning value: T) { take()?.resume(returning: value) }

  func resume(throwing error: Error) { take()?.resume(throwing: error) }

  private func take() -> CheckedContinuation<T, Error>? {
    lock.withLock {
      defer { continuation = nil }
      return continuation
    }
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

/// What generated code exposes so the plugin can donate an intent it cannot
/// name.
///
/// The dependency runs the other way everywhere else: generated Swift calls
/// `OsIntentsBridge`, and a package never reaches into the app target. Donation
/// inverts it — Dart asks for an intent to be donated, and only the app target
/// has the struct — so the generated class registers under a fixed ObjC name
/// and the plugin finds it at runtime. Same shape as the background-engine
/// hook, and for the same reason: the alternative is a line pasted into
/// AppDelegate.
///
/// A completion handler rather than `async` so the declaration stays
/// representable in Objective-C, which is what `NSClassFromString` needs.
@objc public protocol OsIntentsDonating: NSObjectProtocol {
  func donate(
    id: String,
    wire: [String: Any],
    completion: @escaping (Bool) -> Void
  )
}

/// The single point every generated `AppIntent` struct calls into.
///
/// Generated Swift never touches Flutter APIs directly — it only knows
/// `OsIntentsBridge.shared.invoke(id:args:)`. That keeps codegen output stable
/// across Flutter releases.
public final class OsIntentsBridge: @unchecked Sendable {
  public static let shared = OsIntentsBridge()

  /// Scoped locking throughout: `lock()`/`unlock()` are unavailable from async
  /// contexts — holding a lock across a suspension is the hazard they guard
  /// against — and every one of these critical sections sits inside one.
  private let lock = NSLock()
  private var channel: FlutterMethodChannel?
  private var isReady = false
  /// Keyed so a waiter that times out can be taken out on its own, without
  /// releasing anybody else's wait. The value each one is resumed with is
  /// "did this time out".
  private var readyWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

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
  ///
  /// `nonisolated(unsafe)`: set and cleared around one synchronous stretch of
  /// plugin registration on the platform thread, never read from anywhere else.
  public nonisolated(unsafe) static var isRegisteringBackgroundEngine = false

  func attach(channel: FlutterMethodChannel) {
    if Self.isRegisteringBackgroundEngine { return }
    lock.withLock { self.channel = channel }
  }

  func markReady() {
    let waiters = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
      isReady = true
      defer { readyWaiters.removeAll() }
      return Array(readyWaiters.values)
    }
    waiters.forEach { $0.resume(returning: false) }
  }

  func publishStatic(_ values: [String: Any]) {
    Self.staticStore.set(Self.plistSafe(values), forKey: Self.staticKey)
  }

  /// Makes a decoded method-channel payload safe for `UserDefaults`.
  ///
  /// Two things bite here. Dart nulls arrive as `NSNull`, and a single one
  /// anywhere in the tree makes `UserDefaults.set` throw
  /// `NSInvalidArgumentException` and take the whole app down — which it did,
  /// the first time a result with an unset field was published. And nested maps
  /// decode as `[AnyHashable: Any]`, which is not a property list type either.
  ///
  /// Dropping nulls is right rather than lossy: absent and null mean the same
  /// thing to every reader of this data.
  static func plistSafe(_ value: Any) -> Any? {
    switch value {
    case is NSNull:
      return nil
    case let dict as [AnyHashable: Any]:
      var out: [String: Any] = [:]
      for (k, v) in dict {
        guard let key = k as? String, let clean = plistSafe(v) else { continue }
        out[key] = clean
      }
      return out
    case let array as [Any]:
      return array.compactMap { plistSafe($0) }
    case is String, is NSNumber, is Date, is Data:
      return value
    default:
      // Anything else would throw on write; a description keeps the rest of the
      // payload usable instead of losing all of it.
      return String(describing: value)
    }
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
  ///
  /// `nonisolated(unsafe)` because it is a var only so a test can point it
  /// somewhere else; in an app it is `.standard` for the process's lifetime.
  public nonisolated(unsafe) static var staticStore: UserDefaults = .standard

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
    let uiReady = lock.withLock { isReady && channel != nil }
    logInvocationHost(id: id, uiReady: uiReady)

    if uiReady {
      return try await invoke(id: id, args: args)
    }
    return try await OsIntentsBackgroundEngine.shared.invoke(id: id, args: args)
  }

  /// Records which process the OS chose to run `perform()` in.
  ///
  /// This is not decoration. Whether a handler can run without opening the app
  /// depends entirely on the answer: App Intents may be executed in an isolated
  /// system process where no Flutter engine can be started, and an intent that
  /// arrives there cannot be served headlessly no matter what this package
  /// does. Every headless run observed here has been forced from inside the
  /// live app — the one process where an engine is certainly available — so the
  /// interesting case is precisely the one that only a real invocation reaches.
  ///
  /// One line, at the only moment that can tell them apart.
  private func logInvocationHost(id: String, uiReady: Bool) {
    let process = ProcessInfo.processInfo
    NSLog(
      "OSINTENTS_HOST intent=%@ process=%@ pid=%d bundle=%@ uiEngine=%@",
      id,
      process.processName,
      process.processIdentifier,
      Bundle.main.bundleIdentifier ?? "<none>",
      uiReady ? "yes" : "no"
    )
  }

  public func invoke(id: String, args: [String: Any?]) async throws -> IntentOutcome {
    try await waitUntilReady()

    guard let channel = lock.withLock({ self.channel }) else {
      throw OsIntentsError.engineUnavailable
    }

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

  /// The whole stored result for an `Execution.static_` intent.
  ///
  /// Synchronous and engine-free: this path exists precisely so a read-only
  /// action costs nothing and cannot be evicted for memory.
  ///
  /// Whole results rather than the spoken text alone, because storing only the
  /// text would force a `showsSnippet` intent to render an empty card here.
  public func staticResult(for id: String) -> [String: Any]? {
    let values = Self.staticStore.dictionary(forKey: Self.staticKey)
    return values?[id] as? [String: Any]
  }

  public func staticValue(for id: String) -> String? {
    guard let wire = staticResult(for: id) else { return nil }
    return IntentOutcome(wire: wire).spoken
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

    guard let channel = lock.withLock({ self.channel }) else {
      throw OsIntentsError.engineUnavailable
    }

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

  /// Waits for Dart to report its handlers registered, or gives up.
  ///
  /// An intent can launch the app from cold, so this waits rather than failing
  /// outright — but bounded. It was not: the deadline ran in a `Task` whose
  /// thrown error nobody awaited, so `readyTimeout` did nothing and a Dart side
  /// that never reported ready hung the intent until iOS killed it.
  private func waitUntilReady() async throws {
    if lock.withLock({ isReady }) { return }

    let id = UUID()

    // One continuation, resumed exactly once by whichever of these two gets
    // there first — both take the waiter out of the table under the lock, so
    // the race has a single winner. A task group would have been the obvious
    // shape and the wrong one: it awaits its children on the way out, and a
    // checked continuation does not answer cancellation, so the losing side
    // would hang the very path that is meant to report the timeout.
    let deadline = Task { [self, readyTimeout] in
      try await Task.sleep(nanoseconds: UInt64(readyTimeout * 1_000_000_000))
      lock.withLock { readyWaiters.removeValue(forKey: id) }?
        .resume(returning: true)
    }
    defer { deadline.cancel() }

    let timedOut = await withCheckedContinuation {
      (cont: CheckedContinuation<Bool, Never>) in
      let ready = lock.withLock { () -> Bool in
        if isReady { return true }
        readyWaiters[id] = cont
        return false
      }
      if ready { cont.resume(returning: false) }
    }

    if timedOut { throw OsIntentsError.timedOut }
  }
}
