import 'model.dart';

/// Emits the Swift the OS reads at compile time.
///
/// Everything lands in the app target (`ios/Runner/OsIntents/`). Risk #1 showed
/// intents are also picked up from a plugin module, but Risk #1b showed the
/// `AppShortcutsProvider` is not — and since a package in `~/.pub-cache` is
/// shared between projects and wiped by `pub cache repair`, generated sources
/// could never have lived there anyway. See docs/risk1.md.
class SwiftEmitter {
  SwiftEmitter(this.manifest);

  final Manifest manifest;

  /// File name → contents.
  Map<String, String> emit() => {
    'OsIntentsGenerated.swift': _intentsFile(),
    if (manifest.entities.isNotEmpty) 'OsIntentsEntities.swift': _entitiesFile(),
    'OsIntentsShortcuts.swift': _shortcutsFile(),
    if (_needsBackground) 'OsIntentsBackground.swift': _backgroundFile(),
  };

  bool get _needsBackground =>
      manifest.intents.any((i) => i.needsHeadlessEngine);

  /// Supplies the background engine with the two things only the app target
  /// has: which Dart library holds the generated entrypoint, and
  /// `GeneratedPluginRegistrant`.
  ///
  /// Found by the plugin at launch through `NSClassFromString`, so the user
  /// never edits AppDelegate.
  String _backgroundFile() {
    final uri = manifest.entrypointLibraryUri;
    final b = StringBuffer()
      ..writeln(_header)
      ..writeln('import Flutter')
      ..writeln('import Foundation')
      ..writeln('import os_intents_ios')
      ..writeln()
      ..writeln('@objc(OsIntentsBackgroundSetup)')
      ..writeln('class OsIntentsBackgroundSetup: NSObject {')
      ..writeln('  @objc static func configure() {');
    if (uri != null) {
      b.writeln(
        '    OsIntentsBackgroundEngine.entrypointLibraryURI = ${_str(uri)}',
      );
    }
    b
      ..writeln('    OsIntentsBackgroundEngine.pluginRegistrantCallback = {')
      ..writeln('      registry in')
      ..writeln('      GeneratedPluginRegistrant.register(with: registry)')
      ..writeln('    }')
      ..writeln('  }')
      ..writeln('}');
    return b.toString();
  }

  // ── intents ────────────────────────────────────────────────────────────────

  String _intentsFile() {
    final b = StringBuffer()
      ..writeln(_header)
      ..writeln('import AppIntents')
      ..writeln('import Foundation')
      ..writeln('import os_intents_ios')
      ..writeln();

    for (final intent in manifest.intents) {
      b.writeln(_intentStruct(intent));
      b.writeln();
    }
    return b.toString();
  }

  String _intentStruct(IntentSpec i) {
    final b = StringBuffer();
    final resultType = i.phrases.isEmpty
        ? 'some IntentResult & ProvidesDialog'
        : 'some IntentResult & ProvidesDialog';

    b.writeln('@available(iOS 16.0, *)');
    b.writeln('struct ${i.swiftTypeName}: AppIntent {');
    b.writeln('  static let title: LocalizedStringResource = ${_str(i.title)}');
    if (i.description != null) {
      b.writeln(
        '  static let description = IntentDescription(${_str(i.description!)})',
      );
    }
    // Only `foreground` needs the app on screen. This is the whole point of the
    // package, so it is not left to the user to remember.
    b.writeln(
      '  static let openAppWhenRun = ${i.execution == ExecutionMode.foreground}',
    );
    if (!i.showsInSpotlight) {
      b.writeln('  static let isDiscoverable = false');
    }
    b.writeln();

    for (final p in i.params) {
      b.writeln(_parameter(p));
    }
    if (i.params.isNotEmpty) {
      b.writeln();
      b.writeln(_parameterSummary(i));
      b.writeln();
    }

    b.writeln('  func perform() async throws -> $resultType {');
    if (i.execution == ExecutionMode.static_) {
      b.writeln('    // Execution.static_: answered from stored state, with no');
      b.writeln('    // Dart engine started.');
      b.writeln(
        '    if let value = OsIntentsBridge.shared.staticValue(for: ${_str(i.id)}) {',
      );
      b.writeln('      return .result(dialog: IntentDialog(stringLiteral: value))');
      b.writeln('    }');
      b.writeln('    // Nothing published yet — usually a first run, before the');
      b.writeln('    // app has had a chance to call publishStatic. Fall back to');
      b.writeln('    // running the handler rather than answering with silence.');
      b.writeln('    let outcome = try await OsIntentsBridge.shared.invokeBackground(');
      b.writeln('      id: ${_str(i.id)},');
      b.writeln('      args: [:]');
      b.writeln('    )');
      b.writeln(
        '    return .result(dialog: IntentDialog(stringLiteral: outcome.spoken ?? ""))',
      );
    } else {
      // Background intents go through the router, which reuses the UI isolate
      // when the app happens to be running and starts the headless engine only
      // when it is not.
      final method = i.execution == ExecutionMode.background
          ? 'invokeBackground'
          : 'invoke';
      b.writeln('    let outcome = try await OsIntentsBridge.shared.$method(');
      b.writeln('      id: ${_str(i.id)},');
      if (i.params.isEmpty) {
        b.writeln('      args: [:]');
      } else {
        b.writeln('      args: [');
        for (final p in i.params) {
          b.writeln('        ${_str(p.name)}: ${_argExpr(p)},');
        }
        b.writeln('      ]');
      }
      b.writeln('    )');
      b.writeln(
        '    return .result(dialog: IntentDialog(stringLiteral: outcome.spoken ?? ""))',
      );
    }
    b.writeln('  }');
    b.writeln('}');
    return b.toString();
  }

  /// How the action reads as a sentence in the Shortcuts editor.
  ///
  /// Without one, Shortcuts logs "has a parameter without a DOP" and shows the
  /// action with bare parameter slots. Required parameters go in the summary
  /// line; optional ones become the expandable section underneath, which is
  /// what `\.$name` in `whenTaken` would otherwise be needed for.
  String _parameterSummary(IntentSpec i) {
    final required = i.params.where((p) => p.isRequired).toList();
    final optional = i.params.where((p) => !p.isRequired).toList();

    // Built by hand rather than through _str: the summary contains Swift
    // interpolation, `\(\.$name)`, which escaping would turn into literal
    // backslashes and Shortcuts would then show the raw text.
    final title = _escapeInner(i.title);
    final head = required.isEmpty
        ? '"$title"'
        : '"$title \\(\\.\$${required.first.name})"';

    final b = StringBuffer('  static var parameterSummary: some ParameterSummary {\n');
    if (optional.isEmpty) {
      b.writeln('    Summary($head)');
    } else {
      b.writeln('    Summary($head) {');
      for (final p in optional) {
        b.writeln('      \\.\$${p.name}');
      }
      b.writeln('    }');
    }
    b.write('  }');
    return b.toString();
  }

  String _parameter(ParamSpec p) {
    final args = <String>['title: ${_str(p.title)}'];
    if (p.description != null) {
      args.add('description: ${_str(p.description!)}');
    }
    if (p.requestValueDialog != null) {
      args.add('requestValueDialog: ${_str(p.requestValueDialog!)}');
    }
    final optional = p.isRequired ? '' : '?';
    return '  @Parameter(${args.join(', ')})\n'
        '  var ${p.name}: ${p.swiftType}$optional';
  }

  /// Converts a Swift parameter into something the method channel can carry.
  String _argExpr(ParamSpec p) => switch (p.type) {
    // Epoch milliseconds — MethodChannel has no Date, and ISO strings lose the
    // timezone on the Android side.
    ParamType.dateTime => p.isRequired
        ? 'Int(${p.name}.timeIntervalSince1970 * 1000)'
        : '${p.name}.map { Int(\$0.timeIntervalSince1970 * 1000) }',
    // Entities travel as their identifier; the app resolves them itself.
    ParamType.entity => p.isRequired ? '${p.name}.id' : '${p.name}?.id',
    _ => p.name,
  };

  // ── entities ───────────────────────────────────────────────────────────────

  String _entitiesFile() {
    final b = StringBuffer()
      ..writeln(_header)
      ..writeln('import AppIntents')
      ..writeln('import Foundation')
      ..writeln('import os_intents_ios')
      ..writeln();

    for (final e in manifest.entities) {
      b.writeln(_entityStruct(e));
      b.writeln();
      if (e.hasQuery) {
        b.writeln(_entityQuery(e));
        b.writeln();
      }
    }
    return b.toString();
  }

  String _entityStruct(EntitySpec e) {
    final title = e.properties.firstWhere(
      (p) => p.isTitle,
      orElse: () => EntityPropertySpec(name: 'id', type: ParamType.string),
    );
    final subtitle = e.properties.where((p) => p.isSubtitle).firstOrNull;

    final b = StringBuffer();
    b.writeln('@available(iOS 16.0, *)');
    b.writeln('struct ${e.swiftTypeName}: AppEntity, Identifiable {');
    b.writeln('  var id: String');
    for (final p in e.properties) {
      b.writeln('  var ${p.name}: ${p.type.swift}?');
    }
    b.writeln();
    b.writeln(
      '  static let typeDisplayRepresentation: TypeDisplayRepresentation = '
      '${_str(e.displayName ?? e.typeName)}',
    );
    b.writeln();
    b.writeln('  var displayRepresentation: DisplayRepresentation {');
    final titleExpr = 'LocalizedStringResource(stringLiteral: ${title.name} ?? id)';
    if (subtitle != null) {
      b.writeln('    DisplayRepresentation(');
      b.writeln('      title: $titleExpr,');
      b.writeln(
        '      subtitle: ${subtitle.name}.map { LocalizedStringResource(stringLiteral: \$0) }',
      );
      b.writeln('    )');
    } else {
      b.writeln('    DisplayRepresentation(title: $titleExpr)');
    }
    b.writeln('  }');
    b.writeln();
    b.writeln('  static var defaultQuery = ${e.typeName}Query()');
    b.writeln('}');
    return b.toString();
  }

  String _entityQuery(EntitySpec e) {
    final b = StringBuffer();
    b.writeln('@available(iOS 16.0, *)');
    b.writeln('struct ${e.typeName}Query: EntityStringQuery {');
    b.writeln(
      '  func entities(for identifiers: [String]) async throws -> [${e.swiftTypeName}] {',
    );
    b.writeln('    try await OsIntentsBridge.shared.resolveEntities(');
    b.writeln('      type: ${_str(e.typeName)}, ids: identifiers');
    b.writeln('    ).map(${e.swiftTypeName}.init(wire:))');
    b.writeln('  }');
    b.writeln();
    b.writeln(
      '  func entities(matching string: String) async throws -> [${e.swiftTypeName}] {',
    );
    b.writeln('    try await OsIntentsBridge.shared.searchEntities(');
    b.writeln('      type: ${_str(e.typeName)}, query: string');
    b.writeln('    ).map(${e.swiftTypeName}.init(wire:))');
    b.writeln('  }');
    b.writeln();
    b.writeln(
      '  func suggestedEntities() async throws -> [${e.swiftTypeName}] {',
    );
    b.writeln('    try await OsIntentsBridge.shared.suggestedEntities(');
    b.writeln('      type: ${_str(e.typeName)}');
    b.writeln('    ).map(${e.swiftTypeName}.init(wire:))');
    b.writeln('  }');
    b.writeln('}');
    b.writeln();
    b.writeln('@available(iOS 16.0, *)');
    b.writeln('extension ${e.swiftTypeName} {');
    b.writeln('  init(wire: [String: Any]) {');
    b.writeln('    self.id = wire["id"] as? String ?? ""');
    for (final p in e.properties) {
      b.writeln('    self.${p.name} = wire[${_str(p.name)}] as? ${p.type.swift}');
    }
    b.writeln('  }');
    b.writeln('}');
    return b.toString();
  }

  // ── shortcuts ──────────────────────────────────────────────────────────────

  /// The one file that genuinely has to be in the app target.
  ///
  /// Apple selects a single `AppShortcutsProvider`, and only from the app's own
  /// module — measured, not assumed (Risk #1b). If the host app already has a
  /// provider of its own, adding this one is not an error, it is a silent loss;
  /// the CLI checks for that before writing.
  String _shortcutsFile() {
    final withPhrases = manifest.intents
        .where((i) => i.phrases.isNotEmpty)
        .toList();

    final b = StringBuffer()
      ..writeln(_header)
      ..writeln('import AppIntents')
      ..writeln();

    if (withPhrases.isEmpty) {
      b.writeln('// No intent declares phrases, so no provider is needed.');
      b.writeln('// Intents remain reachable from Shortcuts and Spotlight.');
      return b.toString();
    }

    b.writeln('@available(iOS 16.0, *)');
    b.writeln('struct OsIntentsShortcuts: AppShortcutsProvider {');
    b.writeln('  static var appShortcuts: [AppShortcut] {');
    for (final i in withPhrases) {
      b.writeln('    AppShortcut(');
      b.writeln('      intent: ${i.swiftTypeName}(),');
      b.writeln('      phrases: [');
      for (final p in i.phrases) {
        b.writeln('        ${_phrase(p)},');
      }
      b.writeln('      ],');
      b.writeln('      shortTitle: ${_str(i.title)},');
      b.writeln(
        '      systemImageName: ${_str(i.systemImageName ?? 'app.badge')}',
      );
      b.writeln('    )');
    }
    b.writeln('  }');
    b.writeln('}');
    return b.toString();
  }

  /// `$app` becomes `\(.applicationName)`, which Apple requires in every phrase.
  static String _phrase(String raw) {
    final escaped = raw
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll(r'$app', r'\(.applicationName)');
    return '"$escaped"';
  }

  static String _str(String raw) => '"${_escapeInner(raw)}"';

  /// Escapes for a Swift string literal, without adding the quotes.
  static String _escapeInner(String raw) =>
      raw.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  static const String _header = '''
// GENERATED BY os_intents — do not edit.
//
// Regenerate with:
//   dart run build_runner build && dart run os_intents_cli:os_intents sync
''';
}
