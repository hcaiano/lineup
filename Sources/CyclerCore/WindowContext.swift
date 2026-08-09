import Foundation

/// Best-effort enrichment of window titles for the cycle HUD.
///
/// Some apps append a stable context — a browser profile, an account, a workspace — to the AX
/// window title as `<title> - <AppName> - <context>` (the context segment only appears when there
/// is more than one to disambiguate). We pull that context out so the HUD can show it ahead of the
/// title, where it otherwise gets lost to truncation.
///
/// The parser itself is app-agnostic: it just anchors on the app name. The grammar is reliable for
/// Chromium-family browsers, so callers gate it on `supportsTrailingContext(bundleIdentifier:)`
/// rather than running it everywhere — most apps put their name elsewhere in the title (Slack ends
/// with ` - Slack`; editors use em-dashes), where this parser correctly finds nothing. Anything it
/// can't confidently parse is returned untouched, so a window with no context never changes.
public enum WindowContext {
    public struct Parsed: Equatable, Sendable {
        public var title: String
        public var context: String?

        public init(title: String, context: String?) {
            self.title = title
            self.context = context
        }
    }

    /// Split a window `title` into its real title and the trailing context, using `appName` (the
    /// running app's localized name, e.g. `Google Chrome`) as the anchor. Returns the original title
    /// with no context whenever there is no `<title> - <appName> - <context>` suffix to find.
    public static func trailingContext(title: String, appName: String) -> Parsed {
        let untouched = Parsed(title: title, context: nil)
        guard !appName.isEmpty else { return untouched }

        // Anchor on the LAST ` - <appName>`, so a page whose own title contains the app name doesn't
        // fool us into stripping the wrong segment.
        let anchor = " - \(appName)"
        guard let anchorRange = title.range(of: anchor, options: .backwards) else { return untouched }

        // Everything after the anchor must be ` - <context>` for this to be a real context suffix.
        let afterAnchor = title[anchorRange.upperBound...]
        let separator = " - "
        guard afterAnchor.hasPrefix(separator) else { return untouched }
        let suffix = afterAnchor.dropFirst(separator.count).trimmingCharacters(in: .whitespaces)
        guard !suffix.isEmpty else { return untouched }

        let cleanedTitle = title[..<anchorRange.lowerBound].trimmingCharacters(in: .whitespaces)
        return Parsed(title: cleanedTitle, context: normalize(context: suffix))
    }

    /// Whether the trailing-context grammar is trusted for this app. Limited to Chromium-family
    /// browsers, which reliably emit `<tab> - <BrowserName> - <profile>` for multi-profile windows.
    /// The parser is fail-safe, so a mismatch just means no enrichment — but keeping the allowlist
    /// tight avoids running it on apps whose titles happen to look similar by accident.
    public static func supportsTrailingContext(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return chromiumBrowserBundleIDs.contains(bundleIdentifier)
    }

    /// Chromium-family browser bundle IDs (stable + known channels). All share Chrome's window-title
    /// generation, so the trailing-profile grammar holds.
    private static let chromiumBrowserBundleIDs: Set<String> = [
        // Google Chrome
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        // Chromium
        "org.chromium.Chromium",
        // Microsoft Edge
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        // Brave
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        // Vivaldi
        "com.vivaldi.Vivaldi",
        // Opera
        "com.operasoftware.Opera",
        "com.operasoftware.OperaNext",
        "com.operasoftware.OperaDeveloper",
        "com.operasoftware.OperaGX",
    ]

    /// Prefer the final parenthetical's contents (`Henrique (Pessoal)` -> `Pessoal`); otherwise keep
    /// the context verbatim (`Work` -> `Work`). An empty parenthetical falls back to the suffix.
    private static func normalize(context: String) -> String {
        guard context.hasSuffix(")"), let open = context.lastIndex(of: "(") else { return context }
        let inner = context[context.index(after: open)..<context.index(before: context.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? context : inner
    }
}
