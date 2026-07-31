/// Build-time half of os_intents.
///
/// The builder produces two things per annotated library:
///
///   `*.os_intents.g.dart`  the registry `OsIntents.install()` consumes
///   `*.os_intents.json`    the manifest `os_intents_cli sync` turns into Swift
///
/// The split is forced by `build_runner`, which derives output paths from input
/// paths and so cannot write into `ios/`. Emitters are exported here so the CLI
/// can reuse them and so they stay testable without an analyzer in the loop.
library;

export 'src/builder.dart';
export 'src/emit_dart.dart';
export 'src/emit_kotlin.dart';
export 'src/emit_shortcuts.dart';
export 'src/emit_swift.dart';
export 'src/model.dart';
export 'src/parser.dart' show ParseFailure;
