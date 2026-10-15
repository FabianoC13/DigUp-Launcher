import Foundation

/// DigUp's `digup://` links, for running launcher items from scripts, other apps, Shortcuts or a browser:
///
/// - `digup://run/<item id>`: runs the item (the id percent-encoded, as Copy Deeplink writes it).
/// - `digup://search?q=…`: the panel, with that typed.
/// - `digup://ai?q=…`: asks Quick AI.
/// - `digup://quicklink/<name>?q=…`: opens a quicklink by name or keyword, with its argument.
/// - `digup://` alone (or anything else): the panel.
public enum QuicklinksDeeplink: Equatable, Sendable {
    case run(itemID: String)
    case search(query: String)
    case ai(prompt: String)
    case quicklink(name: String, argument: String?)
    case show

    public static let scheme = "digup"

    /// Nil for a URL of another scheme, or a `run` or `quicklink` link that names nothing.
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ names: String...) -> String? {
            for name in names {
                if let found = items.first(where: { $0.name.lowercased() == name })?.value { return found }
            }
            return nil
        }
        let path = String(components.percentEncodedPath.drop { $0 == "/" })
        let rest = path.removingPercentEncoding ?? path
        // The query text, as Raycast's links name it too.
        let text = value("q", "query", "text", "fallbacktext", "argument")
        switch components.host?.lowercased() {
        case "run":
            let id = rest.isEmpty ? (value("id") ?? "") : rest
            guard !id.isEmpty else { return nil }
            self = .run(itemID: id)
        case "search":
            self = .search(query: text ?? rest)
        case "ai":
            self = .ai(prompt: text ?? rest)
        case "quicklink":
            let name = rest.isEmpty ? (value("name") ?? "") : rest
            guard !name.isEmpty else { return nil }
            self = .quicklink(name: name, argument: text)
        default:
            self = .show
        }
    }

    /// The link, with everything but unreserved characters percent-encoded.
    public var url: URL {
        let encode = QuicklinkTemplate.percentEncode
        let text: String
        switch self {
        case .run(let id):
            text = "\(Self.scheme)://run/\(encode(id))"
        case .search(let query):
            text = "\(Self.scheme)://search?q=\(encode(query))"
        case .ai(let prompt):
            text = "\(Self.scheme)://ai?q=\(encode(prompt))"
        case .quicklink(let name, let argument):
            text = "\(Self.scheme)://quicklink/\(encode(name))" + (argument.map { "?q=\(encode($0))" } ?? "")
        case .show:
            text = "\(Self.scheme)://"
        }
        return URL(string: text)!
    }
}
