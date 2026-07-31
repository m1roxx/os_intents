/// Loading the manifests `build_runner` left under `lib/`.
///
/// Shared by `sync` and `doctor` because they must agree on what "declared"
/// means: doctor's whole job is comparing that set against what shipped, and a
/// second copy of this walk would eventually drift from the first.
library;

import 'dart:io';

import 'package:os_intents_gen/os_intents_gen.dart';
import 'package:path/path.dart' as p;

/// A manifest that exists but could not be read — almost always a manifest
/// written by a different version of os_intents.
class ManifestReadException implements Exception {
  ManifestReadException(this.path, this.message);

  /// Absolute path of the offending file.
  final String path;
  final String message;

  @override
  String toString() => '$path: $message';
}

/// Every `*.os_intents.json` under `<root>/lib`, in a stable order.
///
/// Returns an empty list when there are none; the callers word that differently
/// and neither wants an exception for it.
List<Manifest> readManifests(String root) {
  final libDir = Directory(p.join(root, 'lib'));
  if (!libDir.existsSync()) return const [];

  final files =
      libDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.os_intents.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final manifests = <Manifest>[];
  for (final f in files) {
    try {
      manifests.add(Manifest.decode(f.readAsStringSync()));
    } on FormatException catch (e) {
      throw ManifestReadException(f.path, e.message);
    }
  }
  return manifests;
}
