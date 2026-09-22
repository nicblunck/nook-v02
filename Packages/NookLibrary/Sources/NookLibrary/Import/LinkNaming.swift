import Foundation

/// How a saved link gets its name.
///
/// iOS names a shared link in one order: the title the sharing app already
/// resolved and showed in the share sheet, then whatever the page says about
/// itself, and only then the site it came from. Nook follows the same order
/// from every direction — share sheet, drop, paste, the app itself — so the
/// same link is named the same whichever door it came in by.
public enum LinkNaming {

    /// Longer than any title worth showing. Some pages put a whole sentence of
    /// keywords in `<title>`; at that length a name is unreadable in a grid and
    /// useless in a list, and only the opening words carry any meaning.
    public static let maximumTitleLength = 120

    /// A page title trimmed to something fit to display, or nil when the page
    /// offered nothing usable.
    ///
    /// Titles arrive with line breaks, runs of indentation and stray padding
    /// baked in, because they were written to sit inside HTML rather than in a
    /// list of names. Two pages that agree on their title should not produce
    /// two differently spaced names here.
    public static func normalized(_ title: String?) -> String? {
        guard let title else { return nil }

        let collapsed = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maximumTitleLength else { return collapsed }

        // Cut back to the last whole word, so a clipped name never ends
        // halfway through one.
        let clipped = collapsed.prefix(maximumTitleLength)
        let trimmed = clipped.lastIndex(of: " ").map { clipped[clipped.startIndex..<$0] } ?? clipped
        return trimmed.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// What to call a link when nothing has said what the page is: the site it
    /// came from, written the way the system writes it — no scheme, no `www.`,
    /// no trailing path.
    public static func siteName(for url: URL) -> String {
        guard let host = url.host()?.lowercased(), !host.isEmpty else {
            // Something without a host — a `mailto:` or a custom scheme. The
            // whole address is all there is to go on.
            let address = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
            return address.isEmpty ? "Link" : address
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The name a link is saved under, given whatever is known about the page
    /// so far.
    public static func title(pageTitle: String?, url: URL) -> String {
        normalized(pageTitle) ?? siteName(for: url)
    }

    /// Whether a link is still carrying a name Nook picked for it, rather than
    /// one the page or the person gave it.
    ///
    /// Anything Nook has ever fallen back to counts, not just the name it would
    /// choose today — a link saved before this was settled is still waiting for
    /// its real title, and holding its old stand-in against it would strand it
    /// there forever.
    public static func isPlaceholder(_ title: String, for url: URL?) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let url else { return false }

        let standIns: Set<String> = [
            siteName(for: url),
            url.host() ?? "",
            url.absoluteString,
            url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        ]
        return standIns.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
    }
}
