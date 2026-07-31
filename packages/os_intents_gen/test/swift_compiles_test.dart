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
import Flutter

enum GeneratedPluginRegistrant {
  static func register(with registry: FlutterPluginRegistry) {}
}
''';

/// Matches the deployment target the emitted `@available` attributes assume.
const _target = 'arm64-apple-ios16.0-simulator';

void main() {
  final env = _Toolchain.locate();

  group(
    'the emitted Swift',
    () {
      late Directory work;
      late String moduleDir;

      setUpAll(() {
        work = Directory.systemTemp.createTempSync('os_intents_swift');
        moduleDir = env.buildPluginModule(work);
      });

      tearDownAll(() => work.deleteSync(recursive: true));

      void expectsCompiles(String name, Manifest manifest) {
        test(name, () {
          final result = env.typecheck(
            SwiftEmitter(manifest).emit(),
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
    },
    skip: env.skipReason,
  );
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
      params: [
        ParamSpec(
          name: 'title',
          title: 'Title',
          type: ParamType.string,
          isRequired: true,
          requestValueDialog: 'What should it be called?',
        ),
        ParamSpec(name: 'count', title: 'Count', type: ParamType.int_, isRequired: false),
        ParamSpec(name: 'weight', title: 'Weight', type: ParamType.double_, isRequired: false),
        ParamSpec(name: 'urgent', title: 'Urgent', type: ParamType.bool_, isRequired: false),
        ParamSpec(name: 'due', title: 'Due', type: ParamType.dateTime, isRequired: false),
        ParamSpec(
          name: 'project',
          title: 'Project',
          type: ParamType.entity,
          entityTypeName: 'Project',
          isRequired: false,
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
        EntityPropertySpec(name: 'detail', type: ParamType.string, isSubtitle: true),
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
    required this.sdkPath,
    required this.frameworkDir,
    required this.pluginSources,
  }) : skipReason = null;

  _Toolchain.unavailable(this.skipReason)
    : sdkPath = '',
      frameworkDir = '',
      pluginSources = const [];

  /// Why there is nothing to run here, or null when there is.
  final String? skipReason;

  final String sdkPath;

  /// The simulator slice of `Flutter.xcframework`, which the plugin imports.
  final String frameworkDir;

  final List<String> pluginSources;

  static _Toolchain locate() {
    if (!Platform.isMacOS) {
      return _Toolchain.unavailable('swiftc needs macOS');
    }

    final sdk = Process.runSync('xcrun', ['--sdk', 'iphonesimulator', '--show-sdk-path']);
    if (sdk.exitCode != 0) {
      return _Toolchain.unavailable('no iphonesimulator SDK — install Xcode');
    }

    // Located from the Flutter that is running the test rather than a fixed
    // path, so this follows .fvmrc instead of the machine's global SDK.
    final engine = _engineDir();
    if (engine == null) {
      return _Toolchain.unavailable(
        'Flutter.xcframework not found under this Flutter SDK — run '
        '`flutter precache --ios`',
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
        'the os_intents_ios sources are not where expected',
      );
    }

    return _Toolchain(
      sdkPath: (sdk.stdout as String).trim(),
      frameworkDir: p.join(engine, 'ios-arm64_x86_64-simulator'),
      pluginSources: plugin
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
  static String _repoRoot() => p.normalize(p.join(Directory.current.path, '..', '..'));

  static String? _engineDir() {
    for (var dir = p.dirname(Platform.resolvedExecutable); ; ) {
      final candidate = p.join(dir, 'bin', 'cache', 'artifacts', 'engine', 'ios', 'Flutter.xcframework');
      if (Directory(candidate).existsSync()) return candidate;
      final parent = p.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }

  /// Compiles the plugin once, into a module the emitted code can import.
  String buildPluginModule(Directory work) {
    final out = Directory(p.join(work.path, 'module'))..createSync(recursive: true);
    final result = Process.runSync('xcrun', [
      '--sdk', 'iphonesimulator', 'swiftc', '-emit-module',
      '-module-name', 'os_intents_ios',
      '-target', _target,
      '-sdk', sdkPath,
      '-F', frameworkDir,
      '-emit-module-path', p.join(out.path, 'os_intents_ios.swiftmodule'),
      ...pluginSources,
    ]);
    if (result.exitCode != 0) {
      throw StateError('The plugin itself does not compile:\n${result.stderr}');
    }
    return out.path;
  }

  /// Type-checks [files], returning swiftc's complaints — empty when clean.
  String typecheck(
    Map<String, String> files, {
    required Directory into,
    required String moduleDir,
  }) {
    final paths = <String>[p.join(into.path, '_AppProvided.swift')];
    File(paths.first).writeAsStringSync(_appProvided);
    for (final entry in files.entries) {
      final f = File(p.join(into.path, entry.key))..writeAsStringSync(entry.value);
      paths.add(f.path);
    }

    final result = Process.runSync('xcrun', [
      '--sdk', 'iphonesimulator', 'swiftc', '-typecheck',
      '-target', _target,
      '-sdk', sdkPath,
      '-F', frameworkDir,
      '-I', moduleDir,
      ...paths,
    ]);

    // swiftc echoes the offending source under each diagnostic; the first line
    // of each is the one worth reading in a test failure.
    return const LineSplitter()
        .convert('${result.stdout}${result.stderr}')
        .where((l) => l.contains(': error:') || l.contains(': warning:'))
        .map((l) => l.replaceFirst(into.path, ''))
        .join('\n');
  }
}
