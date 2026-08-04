# Roadmap

Where this is going, in order, and what 1.0 means. The inventory of what
already works — verified on a device versus merely compiled — is
[docs/verified.md](docs/verified.md); this file is only about what is next.
Dates are deliberately absent: items ship when they are verified, not when a
calendar says so.

## Toward 0.3

- **Siri invoking a phrase by voice, observed on a physical iPhone.** The
  largest gap in [verified.md](docs/verified.md): the OS running a handler in
  the background is proven from the Shortcuts app, but the voice path needs a
  real device and a spoken phrase, which no simulator can arrange. Closing it
  also produces the demo recording this README should have.
- **An intent invoked on macOS.** The actions reach the built bundle and
  `doctor` reads them back; nobody has yet watched one run there.
- **First real apps shipped on this.** If you want to be one of them, open a
  [discussion](https://github.com/m1roxx/os_intents/discussions) — early
  adopters get hands-on integration help.

## Later, gated on the platforms

- **Interactive snippets that reload (`SnippetIntent`)** — iOS 26 only. Buttons
  on a card already work on iOS 17+; the reload-after-tap half needs the new
  protocol and its own design pass.
- **Android entities** — blocked on the platform, not on this package:
  `androidx.appfunctions` (1.0.0-alpha10) has no entity concept. Revisited on
  every release of that library.
- **An agent invoking an AppFunction end to end** — the bridge half is proven;
  the assistant half waits on Gemini's integration leaving its private EAP.
- **The other fifteen `Measurement` dimensions** — they are iOS 17+ while the
  package floor is 16. Ships as an opt-in the day it can be version-gated
  without raising the floor for everyone.

## Measured and declined

Recorded so they are not re-litigated by accident — each has a written reason:

- **`@AppIntent(schema:)` (Assistant Schemas)** — the macro enforces parameter
  contracts of 143 schemas through protocol conformance, Apple has already
  renamed it once, and emitting one from arbitrary Dart produces Swift that
  does not build. See [docs/verified.md](docs/verified.md).
- **Donation on Android** — the nearest mechanism is a dynamic shortcut, which
  is an app-owned launcher entry, not a hint to a ranking model. It exists
  under its own name (`pushShortcut`) instead of pretending to be `donate`.
- **Making the iOS and Android emitters symmetrical** — the platforms are not.
  One struct per intent on iOS; one service with `@AppFunction` methods on
  Android. Forcing symmetry would mean lying to one of them.

## What 1.0 means

Not a feature list — a set of statements that have to be true:

1. The voice path is verified on a device, so every row of the pitch table is
   backed by an observation.
2. Real apps ship on it, and at least one full release cycle of theirs has
   passed without a breaking change forced by this package.
3. The wire format is frozen and documented as a compatibility promise.
4. `doctor`, `sync --check` and `install --check` have caught, between them,
   every regression class we know about — in CI, before any user saw it.
