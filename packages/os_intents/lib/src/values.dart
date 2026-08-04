import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// What a [Measurement] measures.
///
/// App Intents has no single measurement parameter — it has one per dimension,
/// each with its own unit picker, and the dimension is part of the Swift type.
/// So it cannot be read off a value at run time: it is declared on `@Param` and
/// fixed when the code is generated.
///
/// App Intents has 22 dimensions and **seven of them exist on iOS 16**, which
/// is this package's floor; the other fifteen — area, angle, pressure, power,
/// frequency, information storage and every electrical and optical one —
/// arrived in iOS 17. That was measured against the SDK, not read off
/// documentation, and it is why the list is this short.
///
/// For anything outside it, take a `double` and say the unit in the title.
enum Dimension {
  duration,
  energy,
  length,
  mass,
  speed,
  temperature,
  volume;

  /// The unit [Measurement.value] is expressed in for this dimension.
  ///
  /// The SI base unit throughout, so the rule is one line rather than a table:
  /// metres, kilograms, seconds, kelvin, joules, and so on.
  String get baseUnit => switch (this) {
    Dimension.duration => 's',
    Dimension.energy => 'J',
    Dimension.length => 'm',
    Dimension.mass => 'kg',
    Dimension.speed => 'm/s',
    Dimension.temperature => 'K',
    Dimension.volume => 'L',
  };
}

/// A quantity the user picked with a unit.
///
/// Declare the dimension on the parameter, not on the value:
///
/// ```dart
/// @AppIntent(title: 'Log a run')
/// Future<IntentResult> logRun({
///   @Param(title: 'Distance', dimension: Dimension.length) required Measurement distance,
/// }) async {
///   final km = distance.value / 1000;
///   ...
/// }
/// ```
///
/// [value] is always in the dimension's SI base unit, whatever unit the user
/// chose — the system converts before the value crosses. That is deliberate: a
/// value-and-unit pair on the wire would be a second source of truth for a fact
/// the declaration already fixes, and every handler would have to convert.
@immutable
class Measurement {
  const Measurement(this.value, this.dimension);

  /// The magnitude, in [Dimension.baseUnit].
  final double value;

  final Dimension dimension;

  @override
  bool operator ==(Object other) =>
      other is Measurement &&
      other.value == value &&
      other.dimension == dimension;

  @override
  int get hashCode => Object.hash(value, dimension);

  @override
  String toString() => '$value ${dimension.baseUnit}';
}

/// A file the system handed to an action, or one an action hands back.
///
/// **iOS only.** `androidx.appfunctions` has no counterpart: Android's model is
/// a content URI and a permission grant rather than the bytes themselves, which
/// is a different shape rather than a missing feature. An intent taking one is
/// left out of the AppFunctions surface, and `os_intents sync --android` says
/// so rather than coercing it to a string that would look like it worked.
///
/// Incoming, the file is already on disk: the plugin writes what the system
/// supplied into the app's temporary directory before your handler is called,
/// so [path] can be read straight away. It costs a copy per invocation, which
/// is the price of handing a Dart isolate something the system owns.
///
/// Outgoing — `returns: IntentFile` — [path] must name a file that exists when
/// the handler returns.
@immutable
class IntentFile {
  const IntentFile({required this.path, required this.filename, this.mimeType});

  /// Where the bytes are, on this device's filesystem.
  final String path;

  /// What the file is called, which is not the last segment of [path]: the
  /// system supplies a display name and the copy on disk has a unique one.
  final String filename;

  /// The type the system reported, as a MIME type, when it reported one.
  final String? mimeType;

  /// Reads the whole file.
  ///
  /// Convenience, not the only way — [path] is an ordinary path and a large
  /// file is better streamed.
  Uint8List readBytes() => File(path).readAsBytesSync();

  Map<String, Object?> toWire() => {
    'path': path,
    'filename': filename,
    if (mimeType != null) 'mimeType': mimeType,
  };

  static IntentFile? fromWire(Object? wire) {
    if (wire is! Map) return null;
    final path = wire['path'];
    if (path is! String) return null;
    return IntentFile(
      path: path,
      filename: wire['filename'] as String? ?? path.split('/').last,
      mimeType: wire['mimeType'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is IntentFile &&
      other.path == path &&
      other.filename == filename &&
      other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(path, filename, mimeType);

  @override
  String toString() => 'IntentFile($filename at $path)';
}
