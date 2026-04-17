import Foundation

/// Fetches Open Graph / meta tags from a URL to populate a `LinkPreview`.
/// Fire-and-forget: call `fetch(url:)` from a Task; it returns nil on any failure.
enum LinkPreviewFetcher {

    static func fetch(url: URL) async -> LinkPreview? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400
        else { return nil }

        // Try utf-8 first, fall back to latin-1 (common for older sites).
        guard let html = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        // Limit parsing to the <head> block for speed.
        let head: String
        if let s = html.range(of: "<head", options: .caseInsensitive),
           let e = html.range(of: "</head>", options: .caseInsensitive),
           s.lowerBound < e.upperBound {
            head = String(html[s.lowerBound..<e.upperBound])
        } else {
            head = html
        }

        let ogTitle       = ogTag("og:title",       in: head)
        let ogDescription = ogTag("og:description", in: head)
        let ogImage       = ogTag("og:image",        in: head)
        let ogSiteName    = ogTag("og:site_name",    in: head)

        let title = ogTitle
            ?? metaTag("title",       in: head)
            ?? titleElement(in: head)

        let description = ogDescription
            ?? metaTag("description", in: head)

        let favicon = parseFavicon(from: head, baseURL: url)
            ?? rootFavicon(for: url)

        return LinkPreview(
            url: url.absoluteString,
            title: title.map(decode),
            description: description.map { String(decode($0).prefix(160)) },
            faviconURL: favicon,
            imageURL: ogImage,
            siteName: ogSiteName.map(decode),
            fetchedAt: Date()
        )
    }

    // MARK: - Parsers

    /// Extracts `content="…"` from `<meta property="og:xxx" content="…">` (or reversed).
    private static func ogTag(_ property: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            "property=[\"']\(escaped)[\"'][^>]*content=[\"']([^\"'<>]+)[\"']",
            "content=[\"']([^\"'<>]+)[\"'][^>]*property=[\"']\(escaped)[\"']"
        ]
        for p in patterns { if let v = firstCapture(p, in: html) { return v } }
        return nil
    }

    /// Extracts `content="…"` from `<meta name="xxx" content="…">`.
    private static func metaTag(_ name: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            "name=[\"']\(escaped)[\"'][^>]*content=[\"']([^\"'<>]+)[\"']",
            "content=[\"']([^\"'<>]+)[\"'][^>]*name=[\"']\(escaped)[\"']"
        ]
        for p in patterns { if let v = firstCapture(p, in: html) { return v } }
        return nil
    }

    /// Extracts text from `<title>…</title>`.
    private static func titleElement(in html: String) -> String? {
        firstCapture("<title[^>]*>([^<]+)</title>", in: html)
    }

    /// Parses `<link rel="icon" href="…">` from the head.
    private static func parseFavicon(from html: String, baseURL: URL) -> String? {
        let patterns = [
            "<link[^>]*rel=[\"'](?:shortcut )?icon[\"'][^>]*href=[\"']([^\"'<>]+)[\"']",
            "<link[^>]*href=[\"']([^\"'<>]+)[\"'][^>]*rel=[\"'](?:shortcut )?icon[\"']"
        ]
        for p in patterns {
            guard let path = firstCapture(p, in: html) else { continue }
            if path.hasPrefix("http") { return path }
            return URL(string: path, relativeTo: baseURL)?.absoluteString
        }
        return nil
    }

    /// Falls back to `https://domain/favicon.ico`.
    private static func rootFavicon(for url: URL) -> String? {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.path  = "/favicon.ico"
        c?.query = nil
        return c?.url?.absoluteString
    }

    // MARK: - Regex helper

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTML entity decoding

    private static func decode(_ html: String) -> String {
        html
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
