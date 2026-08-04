// See the note in OsIntentsBridge.swift: Flutter is Objective-C and carries no
// Sendability annotations, so every type it vends reads as non-Sendable.
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
  /// `nonisolated(unsafe)` here and below: generated code in the app target
  /// writes these once, from the plugin registrar during launch, long before
  /// any intent can run. Isolating them to an actor would force the generated
  /// setup to be async for no gain, and the compiler cannot see the ordering on
  /// its own.
  public nonisolated(unsafe) static var pluginRegistrantCallback: ((FlutterPluginRegistry) -> Void)?

  /// Dart entrypoint to run. Generated code overrides both of these to match
  /// the library the annotations were found in.
  public nonisolated(unsafe) static var entrypointName = "osIntentsBackgroundEntrypoint"
  public nonisolated(unsafe) static var entrypointLibraryURI: String?

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

  /// Scoped locking throughout: `lock()`/`unlock()` are unavailable from async
  /// contexts, and most of these critical sections sit inside one.
  private let lock = NSLock()
  private var engine: FlutterEngine?
  private var channel: FlutterMethodChannel?

  /// Keyed so a start that times out can take its own waiter out without
  /// disturbing another invocation waiting on the same engine.
  private var readyContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var isStarting = false
  private var inFlight = 0
  private var idleTimer: DispatchWorkItem?

  private init() {}

  /// True once the background isolate has reported its handlers registered.
  public private(set) var isReady = false

  // MARK: - Invocation

  public func invoke(id: String, args: [String: Any?]) async throws -> IntentOutcome {
    let channel = try await start()

    lock.withLock {
      inFlight += 1
      idleTimer?.cancel()
      idleTimer = nil
    }

    defer { finishedOne() }

    let payload: [String: Any] = ["id": id, "args": args.compactMapValues { $0 }]

    let wire: [String: Any] = try await withCheckedThrowingContinuation { cont in
      let once = OneShotContinuation(cont)

      let deadline = Task { [invokeTimeout] in
        try await Task.sleep(nanoseconds: UInt64(invokeTimeout * 1_000_000_000))
        once.resume(throwing: OsIntentsError.timedOut)
      }

      DispatchQueue.main.async {
        channel.invokeMethod("invoke", arguments: payload) { response in
          deadline.cancel()
          if let error = response as? FlutterError {
            once.resume(throwing: OsIntentsError.handlerFailed(
              error.message ?? error.code
            ))
          } else if let map = response as? [String: Any] {
            once.resume(returning: map)
          } else {
            once.resume(returning: ["kind": "done"])
          }
        }
      }
    }

    if wire["kind"] as? String == "error" {
      throw OsIntentsError.handlerFailed(wire["message"] as? String ?? "unknown")
    }
    return IntentOutcome(wire: wire)
  }

  // MARK: - Lifecycle

  /// Brings the engine up if needed and resolves once Dart has registered.
  private func start() async throws -> FlutterMethodChannel {
    let live = lock.withLock { isReady ? channel : nil }
    if let live { return live }

    let alreadyStarting = lock.withLock { () -> Bool in
      defer { isStarting = true }
      return isStarting
    }
    if !alreadyStarting {
      try startEngine()
    }

    // Bounded, because `run()` returning true only means an isolate was
    // spawned. If the entrypoint is missing, Dart never calls back and this
    // would wait forever — which is exactly how it failed the first time it
    // was tried on a device.
    //
    // The bound is a race between this continuation and a deadline, both of
    // which claim the waiter out of the table under the lock so exactly one
    // wins. Not a task group: that awaits its children on the way out, and a
    // checked continuation ignores cancellation, so the timeout would have hung
    // rather than reported.
    let id = UUID()
    let deadline = Task { [self, startTimeout] in
      try await Task.sleep(nanoseconds: UInt64(startTimeout * 1_000_000_000))
      lock.withLock { readyContinuations.removeValue(forKey: id) }?
        .resume(throwing: OsIntentsError.handlerFailed(
          "The background Dart isolate did not report ready within "
            + "\(Int(startTimeout))s. The usual cause is that the entrypoint "
            + "\"\(Self.entrypointName)\" was not found in "
            + "\(Self.entrypointLibraryURI ?? "the main library")"
            + " — re-run build_runner, then os_intents sync."
        ))
    }
    defer { deadline.cancel() }

    try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<Void, Error>) in
      let ready = lock.withLock { () -> Bool in
        if isReady { return true }
        readyContinuations[id] = cont
        return false
      }
      if ready { cont.resume() }
    }

    guard let channel = lock.withLock({ self.channel }) else {
      throw OsIntentsError.engineUnavailable
    }
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
      #if os(macOS)
      // macOS `FlutterEngine` has no `libraryURI` parameter — the header
      // offers `runWithEntrypoint:` and nothing else — so a headless engine
      // there can only reach an entrypoint in the library that holds `main()`.
      // The generated one is a part of whichever library declared the intents,
      // which is normally not that. Reported rather than started and left to
      // fail with a bare `false`, which is what the missing URI produces.
      if let uri = Self.entrypointLibraryURI {
        failStart(OsIntentsError.handlerFailed(
          "This intent needs a headless Dart engine, and macOS cannot start "
            + "one for an entrypoint outside main.dart: FlutterEngine there "
            + "has no libraryURI parameter. The entrypoint is in \(uri). "
            + "Declare the intent Execution.foreground, or move it into the "
            + "library that holds main()."
        ))
        return
      }
      started = engine.run(withEntrypoint: Self.entrypointName)
      #else
      if let uri = Self.entrypointLibraryURI {
        started = engine.run(
          withEntrypoint: Self.entrypointName,
          libraryURI: uri
        )
      } else {
        started = engine.run(withEntrypoint: Self.entrypointName)
      }
      #endif

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

      lock.withLock {
        self.engine = engine
        self.channel = channel
      }
    }
  }

  private func markReady() {
    let waiters = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
      isReady = true
      isStarting = false
      defer { readyContinuations.removeAll() }
      return Array(readyContinuations.values)
    }
    waiters.forEach { $0.resume() }
  }

  private func failStart(_ error: Error) {
    let waiters = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
      isStarting = false
      defer { readyContinuations.removeAll() }
      return Array(readyContinuations.values)
    }
    waiters.forEach { $0.resume(throwing: error) }
  }

  private func finishedOne() {
    let idle = lock.withLock { () -> Bool in
      inFlight -= 1
      return inFlight <= 0
    }
    guard idle else { return }

    let work = DispatchWorkItem { [weak self] in self?.shutdown() }
    lock.withLock {
      idleTimer?.cancel()
      idleTimer = work
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: work)
  }

  private func shutdown() {
    let engine = lock.withLock { () -> FlutterEngine? in
      guard inFlight <= 0 else { return nil }
      defer {
        self.engine = nil
        self.channel = nil
        isReady = false
        isStarting = false
      }
      return self.engine
    }

    // Two names for the same thing. `destroyContext` is iOS-only; macOS
    // exposes `shutDownEngine`, and its header is explicit that an engine not
    // shut down before it is released leaks.
    #if os(macOS)
    engine?.shutDownEngine()
    #else
    engine?.destroyContext()
    #endif
  }
}
