import 'emit_strings.dart';
import 'model.dart';

/// Emits the Swift the OS reads at compile time.
///
/// Everything lands in the app target (`ios/Runner/OsIntents/`). Risk #1 showed
/// intents are also picked up from a plugin module, but Risk #1b showed the
/// `AppShortcutsProvider` is not — and since a package in `~/.pub-cache` is
/// shared between projects and wiped by `pub cache repair`, generated sources
/// could never have lived there anyway. See docs/risk1.md.
class SwiftEmitter {
  SwiftEmitter(this.manifest, {this.localised = false});

  final Manifest manifest;

  /// Whether user-visible text is looked up in a String Catalogue by key.
  ///
  /// Off by default, and that default is not timidity. A keyed
  /// `LocalizedStringResource` whose catalogue is missing renders as the key
  /// itself — an app shipping "addTask.title" to Siri, with nothing failing
  /// anywhere. So the Swift only starts naming keys once `sync --l10n` is
  /// writing the catalogue that answers them.
  final bool localised;

  /// A title, description or prompt: either the text itself, or a key into the
  /// catalogue.
  ///
  /// The two are interchangeable at the type level — `LocalizedStringResource`
  /// is `ExpressibleByStringLiteral`, and the literal form uses the text as its
  /// own key — so only one of the two ever has a catalogue to answer it.
  String _text(String key, String value) => localised
      ? 'LocalizedStringResource(${_str(key)}, '
            'table: ${_str(StringCatalogEmitter.tableName)})'
      : _str(value);

  /// File name → contents.
  Map<String, String> emit() => {
    'OsIntentsGenerated.swift': _intentsFile(),
    if (manifest.entities.isNotEmpty)
      'OsIntentsEntities.swift': _entitiesFile(),
    if (manifest.enums.isNotEmpty) 'OsIntentsEnums.swift': _enumsFile(),
    'OsIntentsShortcuts.swift': _shortcutsFile(),
    if (_needsBackground) 'OsIntentsBackground.swift': _backgroundFile(),
    if (_needsFiles) 'OsIntentsFiles.swift': _filesFile(),
    'OsIntentsDonations.swift': _donationsFile(),
    'OsIntentsSnippetActions.swift': _snippetActionsFile(),
  };

  bool get _needsBackground =>
      manifest.intents.any((i) => i.needsHeadlessEngine);

  bool get _needsFiles => manifest.intents.any(
    (i) =>
        i.returnType == ParamType.file ||
        i.params.any((p) => p.type == ParamType.file),
  );

  // ── files ──────────────────────────────────────────────────────────────────

  /// Moves an `IntentFile` between the system and a Dart isolate.
  ///
  /// Generated into the app target rather than added to the plugin, and that is
  /// the same division every other AppIntents-shaped thing here follows: the
  /// plugin's deployment floor is iOS 13 and it deals in Flutter types, while
  /// everything that names an App Intents type is emitted and carries
  /// `@available(iOS 16.0, *)`. Importing AppIntents into the plugin to hold
  /// two functions would put that floor at risk for every user of the package.
  ///
  /// Incoming, the bytes are copied into the app's temporary directory. The
  /// system's own `fileURL` is not handed on: it may be security-scoped and
  /// gone by the time an isolate gets to it, and a path that is sometimes
  /// readable is worse than one that always is.
  String _filesFile() =>
      '''
$_header
import AppIntents
import Foundation
import UniformTypeIdentifiers

@available(iOS 16.0, *)
enum OsIntentsFiles {
  /// Spills a file the system supplied to disk, so Dart can read it by path.
  static func wire(_ file: IntentFile?) -> [String: Any]? {
    guard let file else { return nil }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("os_intents", isDirectory: true)
    let target = directory.appendingPathComponent(
      UUID().uuidString + "-" + file.filename
    )
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true
      )
      try file.data.write(to: target)
    } catch {
      // The action itself may still be able to answer, so this reports the
      // parameter as absent rather than failing the whole invocation.
      NSLog("OSINTENTS file %@ could not be staged: %@",
            file.filename, String(describing: error))
      return nil
    }
    var wire: [String: Any] = [
      "path": target.path,
      "filename": file.filename,
    ]
    if let mime = file.type?.preferredMIMEType {
      wire["mimeType"] = mime
    }
    return wire
  }

  /// Rebuilds a file a handler answered with, or one a snippet button carries.
  static func file(fromWire wire: Any?) -> IntentFile? {
    // Nested method-channel maps decode as [AnyHashable: Any], not
    // [String: Any] — the same trap the snippet decoder hit.
    guard let map = wire as? [AnyHashable: Any],
          let path = map["path"] as? String
    else { return nil }
    let url = URL(fileURLWithPath: path)
    let name = map["filename"] as? String ?? url.lastPathComponent
    let type = (map["mimeType"] as? String).flatMap({ UTType(mimeType: \$0) })
    return IntentFile(fileURL: url, filename: name, type: type)
  }
}
''';

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

  // ── donations ──────────────────────────────────────────────────────────────

  /// Rebuilds an intent from wire values so it can be handed to
  /// `IntentDonationManager`.
  ///
  /// The wire format finally runs in both directions here. Everywhere else it
  /// goes intent → Dart: `perform()` encodes its parameters and a handler
  /// decodes them. A donation starts in Dart and has to arrive as a real
  /// `AppIntent` struct, so this is the decode half, and it has to agree with
  /// the encode in [_intentsFile] value for value.
  ///
  /// Found by the plugin through `NSClassFromString`, the same way as
  /// [_backgroundFile]: the structs live in the app target and a package cannot
  /// import them.
  String _donationsFile() {
    final b = StringBuffer()
      ..writeln(_header)
      ..writeln('import AppIntents')
      ..writeln('import Foundation')
      ..writeln('import os_intents_ios')
      ..writeln()
      ..writeln('@objc(OsIntentsDonor)')
      ..writeln('final class OsIntentsDonor: NSObject, OsIntentsDonating {')
      ..writeln('  func donate(')
      ..writeln('    id: String,')
      ..writeln('    wire: [String: Any],')
      ..writeln('    completion: @escaping (Bool) -> Void')
      ..writeln('  ) {')
      ..writeln('    guard #available(iOS 16.0, *) else {')
      ..writeln('      completion(false)')
      ..writeln('      return')
      ..writeln('    }')
      ..writeln('    Task {')
      ..writeln('      switch id {');

    for (final intent in manifest.intents) {
      // `let`, even though every line below assigns to it. `@Parameter`'s
      // setter is nonmutating — it writes into the wrapper's own storage, not
      // into the struct — so `var` earns "variable was never mutated", and the
      // compile test counts a warning as a failure.
      b
        ..writeln('      case ${_str(intent.id)}:')
        ..writeln('        let intent = ${intent.swiftTypeName}()');
      for (final p in intent.params) {
        b.writeln('        ${_wireAssignment(p, from: 'wire')}');
      }
      // `donate` throws. Reporting the failure rather than swallowing it with
      // `try?` costs nothing here and is the difference between "the system
      // declined this" and "nothing was wired up".
      b
        ..writeln('        do {')
        ..writeln(
          '          _ = try await IntentDonationManager.shared.donate(',
        )
        ..writeln('            intent: intent')
        ..writeln('          )')
        ..writeln('          completion(true)')
        ..writeln('        } catch {')
        ..writeln('          completion(false)')
        ..writeln('        }');
    }

    b
      ..writeln('      default:')
      ..writeln('        completion(false)')
      ..writeln('      }')
      ..writeln('    }')
      ..writeln('  }')
      ..writeln('}');
    return b.toString();
  }

  /// One parameter, decoded out of a wire map and assigned if it is there.
  ///
  /// The decode half of the format, shared by the two things that build an
  /// intent from Dart-supplied values rather than from the system: a donation
  /// and a snippet button.
  ///
  /// Every assignment is conditional, including the required ones. A caller who
  /// knows some of the values is better served by a partial intent than by
  /// none — an unset parameter keeps whatever `init()` gave it, and for a
  /// button the system will ask for it.
  String _wireAssignment(ParamSpec p, {required String from}) {
    final raw = '$from[${_str(p.name)}]';
    final expr = switch (p.type) {
      // Numbers arrive as NSNumber whatever Dart sent, so `as? Int` on a value
      // Dart wrote as a double would succeed and silently truncate.
      ParamType.int_ => '($raw as? NSNumber)?.intValue',
      ParamType.double_ => '($raw as? NSNumber)?.doubleValue',
      ParamType.bool_ => '($raw as? NSNumber)?.boolValue',
      // Epoch milliseconds, UTC — the same shape perform() writes out.
      //
      // Parenthesised closures throughout rather than trailing ones: this whole
      // expression is the condition of an `if let`, where swiftc warns that a
      // trailing closure is confusable with the statement's body.
      ParamType.dateTime =>
        '($raw as? NSNumber).map({ Date(timeIntervalSince1970: '
            r'$0.doubleValue / 1000) })',
      ParamType.string => '$raw as? String',
      ParamType.uri => '($raw as? String).flatMap({ URL(string: \$0) })',
      // Microseconds in, seconds out: Measurement is what App Intents offers
      // for a length of time, and the wire carries Dart's own integer form.
      ParamType.duration =>
        '($raw as? NSNumber).map({ Measurement(value: '
            r'$0.doubleValue / 1_000_000, unit: UnitDuration.seconds) })',
      ParamType.measurement =>
        '($raw as? NSNumber).map({ Measurement(value: \$0.doubleValue, '
            'unit: ${p.dimension!.swiftUnitType}.${p.dimension!.baseUnit}) })',
      ParamType.file => 'OsIntentsFiles.file(fromWire: $raw)',
      // An entity crosses as its identifier, so this is the one value a
      // donation cannot fully rebuild: the other properties are display-only
      // and the system re-resolves them through the query.
      ParamType.entity =>
        '($raw as? String).map({ ${p.entityTypeName}Entity(wire: ["id": '
            r'$0]) })',
      ParamType.enum_ =>
        '($raw as? String).flatMap({ ${p.enumTypeName}Enum(rawValue: '
            r'$0) })',
    };
    return 'if let value = $expr { intent.${p.name} = value }';
  }

  // ── snippet buttons ────────────────────────────────────────────────────────

  /// Turns a `SnippetAction` off the wire into a real SwiftUI button.
  ///
  /// The same shape as [_donationsFile], and for the same reason: an intent has
  /// to be a concrete type before anything can be done with it. `Button` is
  /// generic over that type, so the button must be built where the type is
  /// known — here, in the app target — and handed to the plugin's view already
  /// made. `AnyView` erases the view, not the intent.
  ///
  /// **iOS 17.** `Button(intent:)` does not exist below it. The card itself is
  /// iOS 16, so on 16 it simply renders without its buttons rather than not at
  /// all — measured against the SDK, not assumed.
  String _snippetActionsFile() {
    final b = StringBuffer()
      ..writeln(_header)
      ..writeln('import AppIntents')
      ..writeln('import Foundation')
      ..writeln('import SwiftUI')
      ..writeln('import os_intents_ios')
      ..writeln()
      ..writeln('enum OsIntentsSnippetActions {')
      // The availability check lives here rather than at every call site: a
      // generated perform() is iOS 16, and handing it a builder it cannot name
      // would make the whole snippet path 17-only.
      ..writeln('  /// nil below iOS 17, where Button(intent:) does not exist.')
      ..writeln('  @available(iOS 16.0, *)')
      ..writeln('  static var builder: OsIntentsSnippetView.ButtonBuilder? {')
      ..writeln('    if #available(iOS 17.0, *) {')
      ..writeln('      return button(id:args:label:systemImageName:)')
      ..writeln('    }')
      ..writeln('    return nil')
      ..writeln('  }')
      ..writeln()
      ..writeln('  @available(iOS 17.0, *)')
      ..writeln('  static func button(')
      ..writeln('    id: String,')
      ..writeln('    args: [String: Any],')
      ..writeln('    label: String,')
      ..writeln('    systemImageName: String?')
      ..writeln('  ) -> AnyView? {')
      ..writeln('    switch id {');

    for (final intent in manifest.intents) {
      b
        ..writeln('    case ${_str(intent.id)}:')
        ..writeln('      let intent = ${intent.swiftTypeName}()');
      for (final p in intent.params) {
        b.writeln('      ${_wireAssignment(p, from: 'args')}');
      }
      b
        ..writeln('      return AnyView(')
        ..writeln('        Button(intent: intent) {')
        ..writeln('          if let systemImageName {')
        ..writeln('            Label(label, systemImage: systemImageName)')
        ..writeln('          } else {')
        ..writeln('            Text(label)')
        ..writeln('          }')
        ..writeln('        }')
        ..writeln('      )');
    }

    b
      // An id nothing declares leaves the button out. A card missing a button
      // is a smaller failure than a card that will not render.
      ..writeln('    default:')
      ..writeln('      return nil')
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
    // Swift fixes this at compile time, so an intent that only sometimes
    // returns a card still has to declare that it might.
    // Every conformance here has to match what `_dialogReturn` passes: the
    // return type and the `.result(…)` call are one decision made twice, and
    // Swift only complains at the second half.
    final resultType = [
      'some IntentResult',
      if (i.returnType case final r?) 'ReturnsValue<${r.swift}>',
      'ProvidesDialog',
      if (i.showsSnippet) 'ShowsSnippetView',
    ].join(' & ');

    b.writeln('@available(iOS 16.0, *)');
    b.writeln('struct ${i.swiftTypeName}: AppIntent {');
    b.writeln(
      '  static let title: LocalizedStringResource = '
      '${_text(i.titleKey, i.title)}',
    );
    if (i.description != null) {
      b.writeln(
        '  static let description = IntentDescription('
        '${_text(i.descriptionKey, i.description!)})',
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
      b.writeln(_parameter(p, i.id));
    }
    if (i.params.isNotEmpty) {
      b.writeln();
      b.writeln(_parameterSummary(i));
      b.writeln();
    }

    b.writeln('  func perform() async throws -> $resultType {');
    if (i.confirmBeforeRunning case final prompt?) {
      // Before anything else in the body, which is the whole point: a refusal
      // throws out of perform() and the handler is never called. Expressing
      // this as a return value could not work — by then the work is done.
      //
      // The overload carrying a prompt is iOS 18. On 16 and 17 the system still
      // asks, in its own words, so the guarantee holds either way and only the
      // wording is lost.
      b
        ..writeln('    if #available(iOS 18.0, *) {')
        ..writeln('      try await requestConfirmation(')
        ..writeln(
          '        dialog: IntentDialog(${_text(i.confirmKey, prompt)})',
        )
        ..writeln('      )')
        ..writeln('    } else {')
        ..writeln('      try await requestConfirmation()')
        ..writeln('    }');
    }
    if (i.execution == ExecutionMode.static_) {
      b.writeln(
        '    // Execution.static_: answered from stored state, with no',
      );
      b.writeln('    // Dart engine started.');
      b.writeln(
        '    if let stored = OsIntentsBridge.shared.staticResult(for: ${_str(i.id)}) {',
      );
      b.writeln('      let outcome = IntentOutcome(wire: stored)');
      b.writeln('      return ${_dialogReturn(i, 'outcome.spoken ?? ""')}');
      b.writeln('    }');
      b.writeln(
        '    // Nothing published yet — usually a first run, before the',
      );
      b.writeln(
        '    // app has had a chance to call publishStatic. Fall back to',
      );
      b.writeln(
        '    // running the handler rather than answering with silence.',
      );
      b.writeln(
        '    let outcome = try await OsIntentsBridge.shared.invokeBackground(',
      );
      b.writeln('      id: ${_str(i.id)},');
      b.writeln('      args: [:]');
      b.writeln('    )');
      b.writeln('    return ${_dialogReturn(i, 'outcome.spoken ?? ""')}');
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
      b.writeln('    return ${_dialogReturn(i, 'outcome.spoken ?? ""')}');
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

    final b = StringBuffer(
      '  static var parameterSummary: some ParameterSummary {\n',
    );
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

  /// Builds the `return .result(...)` line.
  ///
  /// The view argument only appears for intents that declared showsSnippet,
  /// because the presence of `ShowsSnippetView` in the return type and the
  /// presence of `view:` here have to agree.
  String _dialogReturn(IntentSpec i, String spoken, {String? snippet}) {
    final args = <String>[
      if (i.returnType case final r?) 'value: ${_valueExpr(r)}',
      'dialog: IntentDialog(stringLiteral: $spoken)',
      if (i.showsSnippet)
        // The button builder is handed in rather than looked up, because it is
        // generated code and this is generated code: the plugin's view cannot
        // name an app-target intent, but the call site already can.
        'view: OsIntentsSnippetView(\n'
            '        wire: ${snippet ?? 'outcome.snippet'},\n'
            '        button: OsIntentsSnippetActions.builder\n'
            '      )',
    ];
    return '.result(${args.join(', ')})';
  }

  /// Pulls the returned value out of the outcome at the declared type.
  ///
  /// A handler that declared `returns:` and then answered with something else
  /// — a plain dialog, say — leaves nothing to hand on, and `perform()` still
  /// has to produce a value of that type. The fallback is the type's empty
  /// value rather than a crash: the action did run, and taking down the
  /// Shortcut over a missing return would be the wrong trade.
  static String _valueExpr(ParamType t) => switch (t) {
    ParamType.string => 'outcome.stringValue ?? ""',
    ParamType.int_ => 'outcome.intValue ?? 0',
    ParamType.double_ => 'outcome.doubleValue ?? 0',
    ParamType.bool_ => 'outcome.boolValue ?? false',
    ParamType.dateTime => 'outcome.dateValue ?? Date(timeIntervalSince1970: 0)',
    // A URL has no empty value, so the fallback is a path that exists and
    // means nothing rather than a force-unwrapped literal in a file the user
    // cannot edit.
    ParamType.uri => 'outcome.urlValue ?? URL(fileURLWithPath: "/")',
    ParamType.duration =>
      'outcome.durationValue ?? Measurement(value: 0, unit: UnitDuration.seconds)',
    ParamType.file =>
      'OsIntentsFiles.file(fromWire: outcome.value) '
          '?? IntentFile(data: Data(), filename: "")',
    ParamType.measurement => throw StateError(
      'measurement returns are refused by the parser: the Swift type needs a '
      'dimension and `returns:` has nowhere to put one',
    ),
    ParamType.entity => throw StateError('entity returns are not supported'),
    ParamType.enum_ => throw StateError('enum returns are not supported'),
  };

  String _parameter(ParamSpec p, String intentId) {
    final args = <String>['title: ${_text(p.titleKey(intentId), p.title)}'];
    if (p.description != null) {
      args.add(
        'description: '
        '${_text(p.descriptionKey(intentId), p.description!)}',
      );
    }
    // Which unit the picker opens on, and the one the value is converted to
    // before it crosses. Only the measurement overloads of `@Parameter` accept
    // it, which is why it is not written for anything else.
    if (p.type == ParamType.duration) {
      args.add('defaultUnit: .seconds');
    } else if (p.type == ParamType.measurement) {
      args.add('defaultUnit: .${p.dimension!.baseUnit}');
    }
    if (p.requestValueDialog case final dialog?) {
      // A bare literal is an IntentDialog by conversion; a
      // LocalizedStringResource has to be wrapped in one explicitly.
      final key = p.requestValueDialogKey(intentId);
      args.add(
        'requestValueDialog: '
        '${localised ? 'IntentDialog(${_text(key, dialog)})' : _str(dialog)}',
      );
    }
    final optional = p.isRequired ? '' : '?';
    return '  @Parameter(${args.join(', ')})\n'
        '  var ${p.name}: ${p.swiftType}$optional';
  }

  /// Converts a Swift parameter into something the method channel can carry.
  String _argExpr(ParamSpec p) => switch (p.type) {
    // Epoch milliseconds — MethodChannel has no Date, and ISO strings lose the
    // timezone on the Android side.
    ParamType.dateTime =>
      p.isRequired
          ? 'Int(${p.name}.timeIntervalSince1970 * 1000)'
          : '${p.name}.map { Int(\$0.timeIntervalSince1970 * 1000) }',
    ParamType.uri =>
      p.isRequired ? '${p.name}.absoluteString' : '${p.name}?.absoluteString',
    // Microseconds, which is what Dart's Duration counts in.
    ParamType.duration =>
      p.isRequired
          ? 'Int(${p.name}.converted(to: .seconds).value * 1_000_000)'
          : '${p.name}.map { Int(\$0.converted(to: .seconds).value * 1_000_000) }',
    // The magnitude in the dimension's base unit, whatever unit the user
    // picked — the conversion belongs here rather than in every handler.
    ParamType.measurement =>
      p.isRequired
          ? '${p.name}.converted(to: .${p.dimension!.baseUnit}).value'
          : '${p.name}.map { \$0.converted(to: .${p.dimension!.baseUnit}).value }',
    // Optional either way: the helper takes an optional and answers nil, so a
    // file that could not be staged reads as an absent parameter.
    ParamType.file => 'OsIntentsFiles.wire(${p.name})',
    // Entities travel as their identifier; the app resolves them itself.
    ParamType.entity => p.isRequired ? '${p.name}.id' : '${p.name}?.id',
    // An enum travels as its Dart constant's name, which is exactly the raw
    // value the generated AppEnum is backed by.
    ParamType.enum_ =>
      p.isRequired ? '${p.name}.rawValue' : '${p.name}?.rawValue',
    _ => p.name,
  };

  // ── enums ──────────────────────────────────────────────────────────────────

  /// One `AppEnum` per `@AppEnum`, backed by the Dart constant names.
  ///
  /// `String` raw values rather than the default `Int`, so the wire carries the
  /// name: reordering the Dart enum would otherwise silently repoint every
  /// shortcut a user had already built.
  String _enumsFile() {
    final b = StringBuffer()
      ..writeln(_header)
      ..writeln('import AppIntents')
      ..writeln('import Foundation')
      ..writeln();

    for (final e in manifest.enums) {
      b
        ..writeln('@available(iOS 16.0, *)')
        ..writeln('enum ${e.swiftTypeName}: String, AppEnum, CaseIterable {');
      for (final v in e.values) {
        b.writeln('  case ${v.name}');
      }
      b
        ..writeln()
        ..writeln(
          '  static var typeDisplayRepresentation: TypeDisplayRepresentation {',
        )
        // A literal is a TypeDisplayRepresentation by conversion; a keyed
        // resource needs the `name:` initialiser to become one.
        ..writeln(
          localised
              ? '    TypeDisplayRepresentation(name: '
                    '${_text(e.displayNameKey, e.displayName ?? e.typeName)})'
              : '    ${_str(e.displayName ?? e.typeName)}',
        )
        ..writeln('  }')
        ..writeln()
        ..writeln(
          '  static var caseDisplayRepresentations: '
          '[${e.swiftTypeName}: DisplayRepresentation] {',
        )
        ..writeln('    [');
      for (final v in e.values) {
        b.writeln(
          localised
              ? '      .${v.name}: DisplayRepresentation(title: '
                    '${_text(e.valueKey(v), v.title)}),'
              : '      .${v.name}: ${_str(v.title)},',
        );
      }
      b
        ..writeln('    ]')
        ..writeln('  }')
        ..writeln('}')
        ..writeln();
    }
    return b.toString();
  }

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
      '${localised ? 'TypeDisplayRepresentation(name: '
                '${_text(e.displayNameKey, e.displayName ?? e.typeName)})' : _str(e.displayName ?? e.typeName)}',
    );
    b.writeln();
    b.writeln('  var displayRepresentation: DisplayRepresentation {');
    final titleExpr =
        'LocalizedStringResource(stringLiteral: ${title.name} ?? id)';
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
      b.writeln(
        '    self.${p.name} = wire[${_str(p.name)}] as? ${p.type.swift}',
      );
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
      b.writeln('      shortTitle: ${_text(i.titleKey, i.title)},');
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
