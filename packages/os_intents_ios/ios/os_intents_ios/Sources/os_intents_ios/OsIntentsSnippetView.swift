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

@available(iOS 16.0, *)
public struct OsIntentsSnippetView: View {
  public typealias Row = OsIntentsSnippetRow

  private let title: String
  private let subtitle: String?
  private let imageSystemName: String?
  private let rows: [Row]

  /// Builds from the wire form. A malformed or absent spec produces an empty
  /// title rather than a crash — a blank card is a better failure than taking
  /// the whole action down.
  ///
  /// `nonisolated` because conforming to `View` isolates the whole type to the
  /// main actor, and a generated `perform()` is not on it. Storing four values
  /// touches nothing that isolation protects; without this, every snippet
  /// intent builds with a warning that becomes an error in Swift 6.
  public nonisolated init(wire: [String: Any]?) {
    let spec = wire ?? [:]
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
      }
      Spacer(minLength: 0)
    }
    .padding()
  }
}
