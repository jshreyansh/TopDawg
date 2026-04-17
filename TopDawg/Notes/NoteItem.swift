import Foundation

// MARK: - NoteKind

enum NoteKind: String, Codable {
    case text
    case link
}

// MARK: - LinkPreview

struct LinkPreview: Codable {
    let url: String
    let title: String?
    let description: String?
    let faviconURL: String?
    let imageURL: String?
    let siteName: String?
    let fetchedAt: Date

    /// Best-effort hostname for display (e.g. "github.com")
    var displayHost: String {
        URL(string: url)?.host ?? url
    }
}

// MARK: - NoteItem

struct NoteItem: Identifiable, Codable {
    let id: UUID
    let kind: NoteKind
    var title: String               // first line of text, or page title for links
    let content: String             // full captured text, or URL string
    let sourceApp: String?          // e.g. "Safari", "Finder", "Claude Code"
    let createdAt: Date
    let filePath: String            // absolute path to the saved .md file
    var linkPreview: LinkPreview?   // fetched async after capture; nil for text notes

    // MARK: Convenience

    var url: URL? {
        guard kind == .link else { return nil }
        return URL(string: content)
    }

    /// Resolved display title — uses og:title if available, else raw title.
    var displayTitle: String {
        if kind == .link, let t = linkPreview?.title, !t.isEmpty { return t }
        return title
    }

    /// One-or-two line preview string shown below the title in the tile.
    var shortPreview: String {
        switch kind {
        case .text:
            let lines = content
                .split(separator: "\n", omittingEmptySubsequences: true)
                .dropFirst()            // skip the first line (used as title)
            let joined = lines.prefix(4).joined(separator: " ")
            return joined.isEmpty ? content : String(joined.prefix(120))
        case .link:
            if let d = linkPreview?.description, !d.isEmpty { return String(d.prefix(120)) }
            return URL(string: content)?.host ?? content
        }
    }
}
