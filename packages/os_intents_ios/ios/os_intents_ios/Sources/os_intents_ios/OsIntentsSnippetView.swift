import AppIntents
import SwiftUI

/// Renders the card an `IntentResult.snippet` describes.
///
/// Deliberately not a Flutter view. Siri and Shortcuts render SwiftUI, and
/// there is no way to host a Flutter surface inside them — so the Dart side
/// sends a small declarative spec and this turns it into real SwiftUI. Narrow
/// and predictable beats expressive and broken.
///
/// Lives in the plugin rather than in generated code: it is the same for every
/// app, and shipping it once keeps the generated output readable.
/// One label/value line of a snippet.
///
/// Top-level rather than nested in the view: a type declared inside a `View`
/// inherits the main-actor isolation that conformance implies, which would make
/// `[Row]` unusable from the nonisolated initializer below.
public struct OsIntentsSnippetRow: Hashable, Sendable {
  public let label: String
  public let value: String
}

/// One button on a card, still in wire form.
///
/// The intent it runs is named, not carried: `Button(intent:)` is generic over
/// a concrete type, and this package cannot see the app target's generated
/// structs. Generated code turns this into a real button and hands it back —
/// see `OsIntentsSnippetView.init(wire:button:)`.
///
/// `@unchecked Sendable` for the same reason `@preconcurrency import Flutter`
/// exists in this module: the values come out of a method-channel payload as
/// `Any`, which carries no Sendability, and there is nothing to annotate them
/// with. They are decoded once, never mutated, and only read — and a `View`
/// conformance isolates the storing type to the main actor, so a nonisolated
/// initializer cannot hand them over without this.
public struct OsIntentsSnippetAction: @unchecked Sendable {
  public let label: String
  public let intentId: String
  public let systemImageName: String?
  public let args: [String: Any]
}

@available(iOS 16.0, *)
public struct OsIntentsSnippetView: View {
  public typealias Row = OsIntentsSnippetRow

  public typealias ButtonBuilder = @MainActor (
    _ id: String,
    _ args: [String: Any],
    _ label: String,
    _ systemImageName: String?
  ) -> AnyView?

  private let title: String
  private let subtitle: String?
  private let imageSystemName: String?
  private let rows: [Row]
  private let actions: [OsIntentsSnippetAction]

  /// Supplied by generated code, because only the app target can name an
  /// intent type. Absent means a card with no buttons, which is what every
  /// snippet was before this existed.
  private let button: ButtonBuilder?

  /// Builds from the wire form. A malformed or absent spec produces an empty
  /// title rather than a crash — a blank card is a better failure than taking
  /// the whole action down.
  ///
  /// `nonisolated` because conforming to `View` isolates the whole type to the
  /// main actor, and a generated `perform()` is not on it. Storing four values
  /// touches nothing that isolation protects; without this, every snippet
  /// intent builds with a warning that becomes an error in Swift 6.
  public nonisolated init(
    wire: [String: Any]?,
    button: ButtonBuilder? = nil
  ) {
    self.button = button
    let spec = wire ?? [:]
    actions = (spec["actions"] as? [[String: Any]] ?? []).map {
      OsIntentsSnippetAction(
        label: $0["label"] as? String ?? "",
        intentId: $0["intentId"] as? String ?? "",
        systemImageName: $0["systemImageName"] as? String,
        // Nested method-channel maps decode as [AnyHashable: Any], which is
        // not the shape anything downstream reads.
        args: ($0["args"] as? [AnyHashable: Any] ?? [:]).reduce(
          into: [String: Any]()
        ) { out, pair in
          if let key = pair.key as? String { out[key] = pair.value }
        }
      )
    }
    title = spec["title"] as? String ?? ""
    subtitle = spec["subtitle"] as? String
    imageSystemName = spec["imageSystemName"] as? String
    rows = (spec["rows"] as? [[String: Any]] ?? []).map {
      Row(
        label: $0["label"] as? String ?? "",
        value: $0["value"] as? String ?? ""
      )
    }
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 12) {
      if let imageSystemName {
        Image(systemName: imageSystemName)
          .font(.title2)
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(.headline)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        if !rows.isEmpty {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(rows, id: \.self) { row in
              HStack {
                Text(row.label)
                Spacer(minLength: 12)
                Text(row.value)
                  .foregroundStyle(.secondary)
              }
              .font(.footnote)
            }
          }
          .padding(.top, 2)
        }
        // Buttons need iOS 17 — `Button(intent:)` does not exist below it,
        // measured against the SDK. The card itself is iOS 16, so an older
        // system renders it without them rather than not at all.
        if #available(iOS 17.0, *), button != nil, !actions.isEmpty {
          HStack(spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
              buttonView(for: action)
            }
          }
          .padding(.top, 4)
        }
      }
      Spacer(minLength: 0)
    }
    .padding()
  }

  /// An id nothing declares produces no button rather than a broken card.
  @available(iOS 17.0, *)
  @ViewBuilder
  private func buttonView(for action: OsIntentsSnippetAction) -> some View {
    if let made = button?(
      action.intentId,
      action.args,
      action.label,
      action.systemImageName
    ) {
      made
    }
  }
}
