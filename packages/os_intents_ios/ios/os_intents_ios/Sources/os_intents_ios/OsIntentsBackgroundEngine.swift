import Flutter
import Foundation

/// Runs Dart handlers with no UI.
///
/// Why a second engine at all: when an intent has `openAppWhenRun = false`, iOS
/// launches the app process in the background, but no scene connects. Since
/// Flutter 3.29 the `FlutterViewController` — and with it the engine — is
/// created by the `SceneDelegate` when a scene attaches, so a background launch
/// leaves the app with no engine, no isolate and no method channel. Nothing to
/// invoke.
///
/// So the plugin owns an engine of its own, started on demand and torn down
/// once it goes idle.
public final class OsIntentsBackgroundEngine: @unchecked Sendable {
  public static let shared = OsIntentsBackgroundEngine()

  /// Registers plugins with the background engine.
  ///
  /// `GeneratedPluginRegistrant` lives in the app target, so the plugin cannot
  /// call it directly. The generated `OsIntentsBackground.swift` installs this
  /// from `AppDelegate`. Without it the background isolate comes up with no
  /// plugins — the handler runs, but anything touching shared preferences,
  /// sqlite or the network through a plugin fails.
  public static var pluginRegistrantCallback: ((FlutterPluginRegistry) -> Void)?

  /// Dart entrypoint to run. Generated code overrides both of these to match
  /// the library the annotations were found in.
  public static var entrypointName = "osIntentsBackgroundEntrypoint"
  public static var entrypointLibraryURI: String?

  /// How long the engine lingers after the last invocation.
  ///
  /// Long enough that a burst of intents reuses one isolate, short enough that
  /// a background launch does not keep the process alive for no reason.
  public var idleTimeout: TimeInterval = 20

  /// Ceiling on how long a single handler may take. iOS will eventually kill a
  /// background launch anyway; failing with a clear error beats being killed.
  public var invokeTimeout: TimeInterval = 25

  /// Ceiling on bringing the isolate up and hearing back from Dart.
  public var startTimeout: TimeInterval = 10

  private let lock = NSLock()
  private var engine: FlutterEngine?
  private var channel: FlutterMethodChannel?
  private var readyContinuations: [CheckedContinuation<Void, Error>] = []
  private var isStarting = false
  private var inFlight = 0
  private var idleTimer: DispatchWorkItem?

  private init() {}

  /// True once the background isolate has reported its handlers registered.
  public private(set) var isReady = false

  // MARK: - Invocation

  public func invoke(id: String, args: [String: Any?]) async throws -> IntentOutcome {
    let channel = try await start()

    lock.lock()
    inFlight += 1
    idleTimer?.cancel()
    idleTimer = nil
    lock.unlock()

    defer { finishedOne() }

    let payload: [String: Any] = ["id": id, "args": args.compactMapValues { $0 }]

    let wire: [String: Any] = try await withThrowingTaskGroup(of: [String: Any].self) { group in
      group.addTask {
        try await withCheckedThrowingContinuation { cont in
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
      }
      group.addTask { [invokeTimeout] in
        try await Task.sleep(nanoseconds: UInt64(invokeTimeout * 1_000_000_000))
        throw OsIntentsError.timedOut
      }
      guard let first = try await group.next() else {
        throw OsIntentsError.engineUnavailable
      }
      group.cancelAll()
      return first
    }

    if wire["kind"] as? String == "error" {
      throw OsIntentsError.handlerFailed(wire["message"] as? String ?? "unknown")
    }
    return IntentOutcome(wire: wire)
  }

  // MARK: - Lifecycle

  /// Brings the engine up if needed and resolves once Dart has registered.
  private func start() async throws -> FlutterMethodChannel {
    lock.lock()
    if isReady, let channel {
      lock.unlock()
      return channel
    }
    let alreadyStarting = isStarting
    isStarting = true
    lock.unlock()

    if !alreadyStarting {
      try startEngine()
    }

    // Bounded, because `run()` returning true only means an isolate was
    // spawned. If the entrypoint is missing, Dart never calls back and this
    // would wait forever — which is exactly how it failed the first time it
    // was tried on a device.
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        try await withCheckedThrowingContinuation {
          (cont: CheckedContinuation<Void, Error>) in
          lock.lock()
          if isReady {
            lock.unlock()
            cont.resume()
          } else {
            readyContinuations.append(cont)
            lock.unlock()
          }
        }
      }
      group.addTask { [startTimeout] in
        try await Task.sleep(nanoseconds: UInt64(startTimeout * 1_000_000_000))
        throw OsIntentsError.handlerFailed(
          "The background Dart isolate did not report ready within "
            + "\(Int(startTimeout))s. The usual cause is that the entrypoint "
            + "\"\(Self.entrypointName)\" was not found in "
            + "\(Self.entrypointLibraryURI ?? "the main library")"
            + " — re-run build_runner, then os_intents sync."
        )
      }
      try await group.next()
      group.cancelAll()
    }

    lock.lock()
    let channel = self.channel
    lock.unlock()
    guard let channel else { throw OsIntentsError.engineUnavailable }
    return channel
  }

  private func startEngine() throws {
    // FlutterEngine must be created and run on the main thread.
    DispatchQueue.main.async { [self] in
      let engine = FlutterEngine(
        name: "os_intents.background",
        project: nil,
        allowHeadlessExecution: true
      )

      let started: Bool
      if let uri = Self.entrypointLibraryURI {
        started = engine.run(
          withEntrypoint: Self.entrypointName,
          libraryURI: uri
        )
      } else {
        started = engine.run(withEntrypoint: Self.entrypointName)
      }

      guard started else {
        // Almost always a wrong entrypoint name or a missing
        // @pragma('vm:entry-point') — the tree shaker drops it otherwise.
        failStart(OsIntentsError.handlerFailed(
          "Could not start the background Dart entrypoint "
            + "\"\(Self.entrypointName)\". Re-run build_runner, and check that "
            + "os_intents sync regenerated OsIntentsBackground.swift."
        ))
        return
      }

      OsIntentsBridge.isRegisteringBackgroundEngine = true
      Self.pluginRegistrantCallback?(engine)
      OsIntentsBridge.isRegisteringBackgroundEngine = false

      let channel = FlutterMethodChannel(
        name: "dev.osintents/background",
        binaryMessenger: engine.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        if call.method == "ready" {
          self?.markReady()
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }

      lock.lock()
      self.engine = engine
      self.channel = channel
      lock.unlock()
    }
  }

  private func markReady() {
    lock.lock()
    isReady = true
    isStarting = false
    let waiters = readyContinuations
    readyContinuations.removeAll()
    lock.unlock()
    waiters.forEach { $0.resume() }
  }

  private func failStart(_ error: Error) {
    lock.lock()
    isStarting = false
    let waiters = readyContinuations
    readyContinuations.removeAll()
    lock.unlock()
    waiters.forEach { $0.resume(throwing: error) }
  }

  private func finishedOne() {
    lock.lock()
    inFlight -= 1
    let idle = inFlight <= 0
    lock.unlock()
    guard idle else { return }

    let work = DispatchWorkItem { [weak self] in self?.shutdown() }
    lock.lock()
    idleTimer?.cancel()
    idleTimer = work
    lock.unlock()
    DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: work)
  }

  private func shutdown() {
    lock.lock()
    guard inFlight <= 0 else {
      lock.unlock()
      return
    }
    let engine = self.engine
    self.engine = nil
    self.channel = nil
    isReady = false
    isStarting = false
    lock.unlock()

    engine?.destroyContext()
  }
}
