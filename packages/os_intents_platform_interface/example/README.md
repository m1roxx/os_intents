# What this package is for

You do not depend on this directly. Add
[os_intents](https://pub.dev/packages/os_intents) and this resolves with it.

It exists so that `os_intents` and the two platform implementations can be
released separately, which is the point of the federated layout: a fix in the
iOS bridge does not need a new version of the package your app imports.

## What crosses the boundary

Four things, and each one exists because the system starts the conversation
rather than your app:

```dart
abstract class OsIntentsPlatform extends PlatformInterface {
  /// The OS invoked an intent. `background: true` binds the headless isolate,
  /// which has its own binary messenger and therefore its own channel.
  void setInvocationHandler(
    IntentInvocationHandler handler, {
    bool background = false,
  });

  /// The OS is resolving an entity the user referred to, before any handler
  /// runs — this is what turns "mark **Buy milk** as done" into your object.
  void setEntityHandler(EntityQueryHandler handler, {bool background = false});

  /// Dart handlers are registered. The native side buffers an invocation that
  /// arrives before this resolves, because a cold launch triggered *by* an
  /// intent otherwise races app startup and drops the very thing that started
  /// it.
  Future<void> ready({bool background = false});

  /// Values an `Execution.static_` intent answers from with no Dart running.
  Future<void> publishStaticValues(Map<String, Object?> values);

  /// Tell the system an action happened, so it can suggest it later.
  /// Returns false where the platform has nothing to donate to.
  Future<bool> donate(String id, Map<String, Object?> args);
}
```

## Implementing it

A new platform implementation registers itself the way the two existing ones
do — with `dartPluginClass` in its pubspec, and a static registrar:

```dart
class OsIntentsSomePlatform extends OsIntentsPlatform {
  static void registerWith() {
    OsIntentsPlatform.instance = OsIntentsSomePlatform();
  }
  // …
}
```

The default implementation answers "nothing happened" for everything, so a
platform with no support at all is silent rather than broken.

## The wire format is the contract

`DateTime` crosses as epoch milliseconds UTC, an entity as its identifier, an
enum as its constant's own name — the same in both directions, on both
platforms. Changing one side breaks the other at run time, not at compile time.
