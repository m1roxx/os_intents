/// Declare OS-level app actions in Dart.
///
/// Annotate a function with [AppIntent]; the generator emits the Swift
/// `AppIntent` struct (iOS) and Kotlin `@AppFunction` (Android) that the system
/// needs at compile time, plus the Dart dispatcher that routes an invocation
/// back to your function.
library;

export 'src/annotations.dart';
export 'src/entity.dart';
export 'src/harness.dart';
export 'src/registry.dart';
export 'src/result.dart';
