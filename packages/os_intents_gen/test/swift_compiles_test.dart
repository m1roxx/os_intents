/// Does the emitted Swift actually compile?
///
/// The other emitter tests assert on strings, which is enough to pin the shape
/// of the output but says nothing about whether Swift accepts it. Until now the
/// only thing that answered that was building the example app by hand — so a
/// break in the emitter reached a device before it reached anyone's attention.
///
/// This type-checks the emitter's output against the *real* plugin module, not
/// a stub of it, because the interesting failure is not a syntax error: it is
/// the emitter and `OsIntentsBridge` disagreeing about a method signature, and
/// only the real module can catch that.
///
/// Warnings count as failures. Every one seen so far has been a Swift 6
/// language-mode error in waiting, and a warning that lands in a user's build
/// log comes from a file they cannot edit.
///
/// Needs macOS with Xcode and the pinned Flutter's engine artifacts; skips
/// itself, with the reason, anywhere else.
library;

import 'dart:convert';
import 'dart:io';

import 'package:os_intents_gen/os_intents_gen.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Flutter generates this into the app target. It is not part of the os_intents
/// surface and nothing outside a real app build provides it, so it is the one
/// thing here that is stubbed rather than compiled from source.
const _appProvided = '''
#if canImport(FlutterMacOS)
import FlutterMacOS
#else
import Flutter
#endif

// Two different shapes, not one name spelled twice: iOS gets an Objective-C
// class with a `+registerWithRegistry:`, macOS a free Swift function. Both are
// stubbed here in the shape Flutter actually generates, so the generated
// background file has to name the right one per platform to compile.
#if os(macOS)
func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {}
#else
enum GeneratedPluginRegistrant {
  static func register(with registry: FlutterPluginRegistry) {}
}
#endif
''';

/// A platform the emitted Swift has to compile for.
///
/// Both, since macOS arrived: the generated code names macOS floors alongside
/// the iOS ones and the plugin it calls compiles under `#if os(macOS)`, so a
/// difference between them is exactly the kind of thing only a second
/// type-check finds. Each deployment target matches the lowest floor the
/// emitted `@available` attributes assume.
enum _Platform {
  ios(
    sdk: 'iphonesimulator',
    target: 'arm64-apple-ios16.0-simulator',
    pluginTarget: 'arm64-apple-ios13.0-simulator',
    engine: 'ios',
    framework: 'Flutter.xcframework',
    slice: 'ios-arm64_x86_64-simulator',
    precache: 'flutter precache --ios',
  ),
  macos(
    sdk: 'macosx',
    target: 'arm64-apple-macos13.0',
    pluginTarget: 'arm64-apple-macos10.15',
    engine: 'darwin-x64',
    framework: 'FlutterMacOS.xcframework',
    slice: 'macos-arm64_x86_64',
    precache: 'flutter precache --macos',
  );

  const _Platform({
    required this.sdk,
    required this.target,
    required this.pluginTarget,
    required this.engine,
    required this.framework,
    required this.slice,
    required this.precache,
  });

  final String sdk;

  /// Deployment target for the *generated* code, matching the lowest floor its
  /// `@available` attributes assume.
  final String target;

  /// Deployment target for the *plugin*, matching the floor its podspec and
  /// Package.swift declare — much lower, and the one a real build uses.
  ///
  /// The distinction is not academic. A macOS build of the plugin failed at
  /// 10.15 on SwiftUI API that is fine at 13, and type-checking it at 13 said
  /// nothing was wrong. The floor a thing ships at is the floor to check it at.
  final String pluginTarget;

  final String engine;
  final String framework;
  final String slice;
  final String precache;
}

void main() {
  for (final platform in _Platform.values) {
    _runFor(_Toolchain.locate(platform), platform);
  }
}

void _runFor(_Toolchain env, _Platform platform) {
  group('the emitted Swift, on ${platform.name}', () {
    late Directory work;
    late String moduleDir;

    setUpAll(() {
      work = Directory.systemTemp.createTempSync('os_intents_swift');
      moduleDir = env.buildPluginModule(work);
    });

    tearDownAll(() => work.deleteSync(recursive: true));

    void expectsCompiles(
      String name,
      Manifest manifest, {
      bool localised = false,
    }) {
      test(name, () {
        final result = env.typecheck(
          SwiftEmitter(manifest, localised: localised).emit(),
          into: Directory(p.join(work.path, name.replaceAll(' ', '_')))
            ..createSync(recursive: true),
          moduleDir: moduleDir,
        );
        expect(result, isEmpty, reason: 'swiftc reported:\n$result');
      });
    }

    expectsCompiles('every parameter type, entity and execution mode', _full);
    expectsCompiles('strings that have to survive escaping', _awkward);
    expectsCompiles('one intent and nothing else', _minimal);

    // The localised output is a different program, not the same one with the
    // literals swapped: a keyed `LocalizedStringResource` is not
    // interchangeable with a literal everywhere the literal was accepted.
    // `TypeDisplayRepresentation` and `IntentDialog` both take one only through
    // an initialiser, and a case display representation stops being a bare
    // string. Each of those is a compile error rather than a wrong word.
    expectsCompiles('all of it again, keyed', _full, localised: true);
    expectsCompiles('and the awkward strings keyed', _awkward, localised: true);

    // Not the emitter's output, but the module it is generated to call, and
    // the only thing standing between it and a Swift 6 build is this check:
    // the language mode turns the concurrency warnings it was cleaned of back
    // into errors, one file at a time, as soon as anyone stops looking.
    test('the plugin it calls compiles under the Swift 6 language mode', () {
      expect(env.typecheckPlugin(swiftVersion: '6'), isEmpty);
    });
  }, skip: env.skipReason);
}

/// Exercises every branch the emitter has: all three execution modes, every
/// parameter type, an entity with a query, phrases, and a snippet.
final _full = Manifest(
  source: 'app|lib/intents.dart',
  intents: [
    IntentSpec(
      id: 'addTask',
      functionName: 'addTask',
      title: 'Add task',
      description: 'Creates a task',
      execution: ExecutionMode.background,
      phrases: [r'Add a task to $app', r'New $app task'],
      systemImageName: 'plus.circle',
      // Type-checked here rather than only asserted as a string: the call is
      // version-gated and the iOS 18 overload takes a required dialog, so a
      // wrong shape is a compile error rather than a wrong prompt.
      confirmBeforeRunning: r'Add "a task" to the inbox?',
      params: [
        ParamSpec(
          name: 'title',
          title: 'Title',
          type: ParamType.string,
          isRequired: true,
          requestValueDialog: 'What should it be called?',
        ),
        ParamSpec(
          name: 'count',
          title: 'Count',
          type: ParamType.int_,
          isRequired: false,
        ),
        ParamSpec(
          name: 'weight',
          title: 'Weight',
          type: ParamType.double_,
          isRequired: false,
        ),
        ParamSpec(
          name: 'urgent',
          title: 'Urgent',
          type: ParamType.bool_,
          isRequired: false,
        ),
        ParamSpec(
          name: 'due',
          title: 'Due',
          type: ParamType.dateTime,
          isRequired: false,
        ),
        ParamSpec(
          name: 'project',
          title: 'Project',
          type: ParamType.entity,
          entityTypeName: 'Project',
          isRequired: false,
        ),
        ParamSpec(
          name: 'priority',
          title: 'Priority',
          type: ParamType.enum_,
          enumTypeName: 'Priority',
          isRequired: false,
        ),
        ParamSpec(
          name: 'link',
          title: 'Link',
          type: ParamType.uri,
          isRequired: false,
        ),
        ParamSpec(
          name: 'remindIn',
          title: 'Remind in',
          type: ParamType.duration,
          isRequired: false,
        ),
        ParamSpec(
          name: 'distance',
          title: 'Distance',
          type: ParamType.measurement,
          dimension: MeasurementDimension.length,
          isRequired: false,
        ),
        ParamSpec(
          name: 'document',
          title: 'Document',
          type: ParamType.file,
          isRequired: false,
        ),
      ],
    ),
    // The required half of each new type. `_argExpr` writes a different
    // expression for a required parameter than for an optional one — the
    // optional path maps over it — so one of each is two code paths, not one.
    IntentSpec(
      id: 'logRun',
      functionName: 'logRun',
      title: 'Log a run',
      execution: ExecutionMode.background,
      params: [
        ParamSpec(
          name: 'route',
          title: 'Route',
          type: ParamType.uri,
          isRequired: true,
        ),
        ParamSpec(
          name: 'elapsed',
          title: 'Elapsed',
          type: ParamType.duration,
          isRequired: true,
        ),
        ParamSpec(
          name: 'distance',
          title: 'Distance',
          type: ParamType.measurement,
          dimension: MeasurementDimension.length,
          isRequired: true,
        ),
        ParamSpec(
          name: 'photo',
          title: 'Photo',
          type: ParamType.file,
          isRequired: true,
        ),
      ],
    ),
    // Every dimension has its own `defaultUnit` namespace with its own cases,
    // and `.converted(to:)` has to name a unit that exists on that class. The
    // table in [MeasurementDimension] was read out of the SDK; this is what
    // proves it was read correctly, all 22 at once.
    IntentSpec(
      id: 'everyDimension',
      functionName: 'everyDimension',
      title: 'Every dimension',
      execution: ExecutionMode.background,
      params: [
        for (final d in MeasurementDimension.values)
          ParamSpec(
            name: d.name,
            title: d.name,
            type: ParamType.measurement,
            dimension: d,
            isRequired: true,
          ),
      ],
    ),
    IntentSpec(
      id: 'dueToday',
      functionName: 'dueToday',
      title: 'Tasks due today',
      execution: ExecutionMode.static_,
      phrases: [r"What's due today in $app"],
      showsSnippet: true,
    ),
    IntentSpec(
      id: 'openInbox',
      functionName: 'openInbox',
      title: 'Open inbox',
      execution: ExecutionMode.foreground,
    ),
    // One per returnable type: `ReturnsValue<T>` puts T in `perform()`'s
    // signature, so a coercion that does not match is a compile error here
    // rather than a Shortcut that hands on the wrong thing.
    IntentSpec(
      id: 'countTasks',
      functionName: 'countTasks',
      title: 'Count tasks',
      execution: ExecutionMode.background,
      returnType: ParamType.int_,
    ),
    IntentSpec(
      id: 'nextTitle',
      functionName: 'nextTitle',
      title: 'Next task title',
      execution: ExecutionMode.static_,
      returnType: ParamType.string,
    ),
    IntentSpec(
      id: 'averageLoad',
      functionName: 'averageLoad',
      title: 'Average load',
      execution: ExecutionMode.background,
      returnType: ParamType.double_,
    ),
    IntentSpec(
      id: 'isBusy',
      functionName: 'isBusy',
      title: 'Is busy',
      execution: ExecutionMode.background,
      returnType: ParamType.bool_,
    ),
    IntentSpec(
      id: 'lastRoute',
      functionName: 'lastRoute',
      title: 'Last route',
      execution: ExecutionMode.background,
      returnType: ParamType.uri,
    ),
    IntentSpec(
      id: 'timeSpent',
      functionName: 'timeSpent',
      title: 'Time spent',
      execution: ExecutionMode.background,
      returnType: ParamType.duration,
    ),
    IntentSpec(
      id: 'exportTasks',
      functionName: 'exportTasks',
      title: 'Export tasks',
      execution: ExecutionMode.background,
      returnType: ParamType.file,
    ),
    // Returning a value *and* showing a card: both conformances land in the
    // same return type, and the `.result(…)` call has to carry both arguments.
    IntentSpec(
      id: 'nextDue',
      functionName: 'nextDue',
      title: 'Next due date',
      execution: ExecutionMode.background,
      returnType: ParamType.dateTime,
      showsSnippet: true,
    ),
  ],
  enums: [
    // AppEnum is a protocol with real requirements — RawRepresentable,
    // CaseIterable, and a caseDisplayRepresentations keyed by Self. Getting
    // any of them wrong is a compile error, which is the point of this test.
    EnumSpec(
      typeName: 'Priority',
      dartClassName: 'Priority',
      displayName: 'Priority',
      values: [
        EnumValueSpec(name: 'whenever', title: 'Whenever'),
        EnumValueSpec(name: 'veryUrgent', title: 'Very urgent'),
      ],
    ),
  ],
  entities: [
    EntitySpec(
      typeName: 'Project',
      dartClassName: 'ProjectEntity',
      idProperty: 'id',
      displayName: 'Project',
      hasQuery: true,
      queryClassName: 'ProjectQuery',
      properties: [
        EntityPropertySpec(name: 'name', type: ParamType.string, isTitle: true),
        EntityPropertySpec(
          name: 'detail',
          type: ParamType.string,
          isSubtitle: true,
        ),
      ],
    ),
  ],
);

/// Quotes, backslashes and non-ASCII in every string that reaches a Swift
/// literal. Escaping is where a string-building emitter breaks first, and a
/// broken literal is a compile error rather than a wrong value.
final _awkward = Manifest(
  source: 'app|lib/intents.dart',
  intents: [
    IntentSpec(
      id: 'quote',
      functionName: 'quote',
      title: r'Say "hello" \ goodbye',
      description: r'A description with "quotes", a \backslash and — a dash',
      execution: ExecutionMode.background,
      phrases: [r'Say "hi" in $app'],
      params: [
        ParamSpec(
          name: 'text',
          title: r'The "text" \ value',
          type: ParamType.string,
          isRequired: true,
          description: 'Ünïcödé and emoji 🎉',
          requestValueDialog: r'Which "text"?',
        ),
      ],
    ),
  ],
);

final _minimal = Manifest(
  source: 'app|lib/intents.dart',
  intents: [
    IntentSpec(
      id: 'ping',
      functionName: 'ping',
      title: 'Ping',
      execution: ExecutionMode.foreground,
    ),
  ],
);

/// Everything needed to run swiftc against the plugin, or a reason there is
/// nothing to run.
class _Toolchain {
  _Toolchain({
    required this.platform,
    required this.sdkPath,
    required this.frameworkDir,
    required this.pluginSources,
  }) : skipReason = null;

  _Toolchain.unavailable(this.platform, this.skipReason)
    : sdkPath = '',
      frameworkDir = '',
      pluginSources = const [];

  final _Platform platform;

  /// Why there is nothing to run here, or null when there is.
  final String? skipReason;

  final String sdkPath;

  /// The simulator slice of `Flutter.xcframework`, which the plugin imports.
  final String frameworkDir;

  final List<String> pluginSources;

  static _Toolchain locate(_Platform platform) {
    if (!Platform.isMacOS) {
      return _Toolchain.unavailable(platform, 'swiftc needs macOS');
    }

    final sdk = Process.runSync('xcrun', [
      '--sdk',
      platform.sdk,
      '--show-sdk-path',
    ]);
    if (sdk.exitCode != 0) {
      return _Toolchain.unavailable(
        platform,
        'no ${platform.sdk} SDK — install Xcode',
      );
    }

    // Located from the Flutter that is running the test rather than a fixed
    // path, so this follows .fvmrc instead of the machine's global SDK.
    final engine = _engineDir(platform);
    if (engine == null) {
      return _Toolchain.unavailable(
        platform,
        '${platform.framework} not found under this Flutter SDK — run '
        '`${platform.precache}`',
      );
    }

    final plugin = Directory(
      p.join(
        _repoRoot(),
        'packages/os_intents_ios/ios/os_intents_ios/Sources/os_intents_ios',
      ),
    );
    if (!plugin.existsSync()) {
      return _Toolchain.unavailable(
        platform,
        'the os_intents_ios sources are not where expected',
      );
    }

    return _Toolchain(
      platform: platform,
      sdkPath: (sdk.stdout as String).trim(),
      frameworkDir: p.join(engine, platform.slice),
      pluginSources:
          plugin
              .listSync()
              .whereType<File>()
              .map((f) => f.path)
              .where((f) => f.endsWith('.swift'))
              .toList()
            ..sort(),
    );
  }

  /// Tests run from their package directory, and this one reaches across the
  /// workspace on purpose: the emitter's output is only meaningful against the
  /// plugin it is generated to call.
  static String _repoRoot() =>
      p.normalize(p.join(Directory.current.path, '..', '..'));

  static String? _engineDir(_Platform platform) {
    for (var dir = p.dirname(Platform.resolvedExecutable); ;) {
      final candidate = p.join(
        dir,
        'bin',
        'cache',
        'artifacts',
        'engine',
        platform.engine,
        platform.framework,
      );
      if (Directory(candidate).existsSync()) return candidate;
      final parent = p.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }

  /// Compiles the plugin once, into a module the emitted code can import.
  String buildPluginModule(Directory work) {
    final out = Directory(p.join(work.path, 'module'))
      ..createSync(recursive: true);
    final result = Process.runSync('xcrun', [
      '--sdk',
      platform.sdk,
      'swiftc',
      '-emit-module',
      '-module-name',
      'os_intents_ios',
      '-target',
      platform.target,
      '-sdk',
      sdkPath,
      '-F',
      frameworkDir,
      '-emit-module-path',
      p.join(out.path, 'os_intents_ios.swiftmodule'),
      ...pluginSources,
    ]);
    if (result.exitCode != 0) {
      throw StateError('The plugin itself does not compile:\n${result.stderr}');
    }
    return out.path;
  }

  /// Type-checks the plugin's own sources, returning swiftc's complaints.
  String typecheckPlugin({String? swiftVersion}) => _diagnostics(
    Process.runSync('xcrun', [
      '--sdk',
      platform.sdk,
      'swiftc',
      '-typecheck',
      '-module-name',
      'os_intents_ios',
      if (swiftVersion != null) ...['-swift-version', swiftVersion],
      '-target',
      platform.pluginTarget,
      '-sdk',
      sdkPath,
      '-F',
      frameworkDir,
      ...pluginSources,
    ]),
    strip: p.dirname(pluginSources.first),
  );

  /// Type-checks [files], returning swiftc's complaints — empty when clean.
  String typecheck(
    Map<String, String> files, {
    required Directory into,
    required String moduleDir,
  }) {
    final paths = <String>[p.join(into.path, '_AppProvided.swift')];
    File(paths.first).writeAsStringSync(_appProvided);
    for (final entry in files.entries) {
      final f = File(p.join(into.path, entry.key))
        ..writeAsStringSync(entry.value);
      paths.add(f.path);
    }

    return _diagnostics(
      Process.runSync('xcrun', [
        '--sdk',
        platform.sdk,
        'swiftc',
        '-typecheck',
        '-target',
        platform.target,
        '-sdk',
        sdkPath,
        '-F',
        frameworkDir,
        '-I',
        moduleDir,
        ...paths,
      ]),
      strip: into.path,
    );
  }

  /// swiftc echoes the offending source under each diagnostic; the first line
  /// of each is the one worth reading in a test failure.
  static String _diagnostics(ProcessResult result, {required String strip}) =>
      const LineSplitter()
          .convert('${result.stdout}${result.stderr}')
          .where((l) => l.contains(': error:') || l.contains(': warning:'))
          .map((l) => l.replaceFirst(strip, ''))
          .join('\n');
}
