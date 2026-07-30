import 'package:meta/meta.dart';
import 'package:meta/meta_meta.dart';

/// Marks a class as a domain object the system can reason about.
///
/// This is what makes "mark *Buy milk* as done" work: the OS resolves the
/// spoken string to one of your entities before your handler ever runs.
@immutable
@Target({TargetKind.classType})
class AppEntity {
  const AppEntity({required this.typeName, this.displayName});

  /// Stable type name on the wire. Renaming it invalidates entities already
  /// referenced by user-built shortcuts, so pick it once.
  final String typeName;

  final String? displayName;
}

/// The property holding the entity's stable identifier.
@immutable
@Target({TargetKind.field, TargetKind.getter})
class EntityId {
  const EntityId();
}

/// Maps a property into the entity's `DisplayRepresentation`.
@immutable
@Target({TargetKind.field, TargetKind.getter})
class EntityDisplay {
  const EntityDisplay({
    this.title = false,
    this.subtitle = false,
    this.image = false,
  });

  final bool title;
  final bool subtitle;
  final bool image;
}

/// Marks a class as the lookup strategy for [T].
///
/// The generator wires it into a Swift `EntityStringQuery`, so the methods here
/// are called by the OS during disambiguation — not by your own code.
@immutable
@Target({TargetKind.classType})
class EntityQuery {
  const EntityQuery(this.entityType);
  final Type entityType;
}

/// Implement alongside an [EntityQuery]-annotated class.
abstract interface class EntityResolver<T> {
  /// Resolve already-known identifiers back to entities.
  Future<List<T>> byIds(List<String> ids);

  /// Free-text match, used when the user said something ambiguous.
  Future<List<T>> matching(String query);

  /// Entities offered up front in the Shortcuts editor.
  Future<List<T>> suggested();
}
