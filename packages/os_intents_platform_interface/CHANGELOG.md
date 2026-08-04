## 0.2.0

### Dynamic shortcuts

Four methods for launcher shortcuts an app publishes at runtime:
`pushDynamicShortcut`, `dynamicShortcuts`, `removeDynamicShortcuts` and
`maxDynamicShortcuts`. The unimplemented default answers "nothing published"
for all of them, so a platform without a launcher needs no code.

## 0.1.0

First released version. The contract between
[os_intents](https://pub.dev/packages/os_intents) and its platform
implementations — you depend on that package, and this one resolves with it.

Defines how an invocation, an entity query, published static values and a
donation cross between Dart and each platform.
