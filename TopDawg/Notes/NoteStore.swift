import Foundation
import AppKit

/// Owns the list of saved notes, handles file I/O, and kicks off async link-preview fetches.
final class NoteStore: ObservableObject {

    @Published private(set) var notes: [NoteItem] = []

    // MARK: - Storage

    static let storageDir: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("TopDawg/Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() { loadAll() }

    // MARK: - Capture API

    func captureText(_ text: String, from app: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let firstLine = String(
            trimmed.split(separator: "\n", omittingEmptySubsequences: true)
                .first ?? Substring(trimmed)
        )

        let item = NoteItem(
            id: UUID(),
            kind: .text,
            title: String(firstLine.prefix(80)),
            content: trimmed,
            sourceApp: app,
            createdAt: Date(),
            filePath: newFilePath(suffix: "text"),
            linkPreview: nil
        )
        write(item)
        DispatchQueue.main.async { self.notes.insert(item, at: 0) }
    }

    func captureLink(_ url: URL, from app: String?) {
        let stub = NoteItem(
            id: UUID(),
            kind: .link,
            title: url.host ?? url.absoluteString,
            content: url.absoluteString,
            sourceApp: app,
            createdAt: Date(),
            filePath: newFilePath(suffix: "link"),
            linkPreview: nil
        )
        write(stub)
        DispatchQueue.main.async { self.notes.insert(stub, at: 0) }

        // Fetch Open Graph preview in background; update the item when done.
        Task {
            guard let preview = await LinkPreviewFetcher.fetch(url: url) else { return }
            var enriched = stub
            enriched.linkPreview = preview
            if let t = preview.title, !t.isEmpty { enriched.title = t }
            self.write(enriched)
            await MainActor.run {
                if let idx = self.notes.firstIndex(where: { $0.id == stub.id }) {
                    self.notes[idx] = enriched
                }
            }
        }
    }

    func delete(_ item: NoteItem) {
        try? FileManager.default.removeItem(atPath: item.filePath)
        DispatchQueue.main.async {
            self.notes.removeAll { $0.id == item.id }
        }
    }

    // MARK: - Persistence

    /// Writes a human-readable .md file whose first line embeds JSON metadata so
    /// we can round-trip the full NoteItem without a separate database.
    ///
    /// Format:
    /// ```
    /// <!-- TOPDAWG_NOTE {"id":"…","kind":"text",…} -->
    ///
    /// # Title
    ///
    /// Content…
    ///
    /// ---
    /// Captured Apr 16, 2026, 14:32 · Safari
    /// ```
    func write(_ item: NoteItem) {
        guard let metaData = try? encoder.encode(item),
              let metaJSON = String(data: metaData, encoding: .utf8) else { return }

        let dateStr = Self.displayFormatter.string(from: item.createdAt)
        let appStr  = item.sourceApp.map { " · \($0)" } ?? ""

        let body: String
        switch item.kind {
        case .text:
            body = "# \(item.title)\n\n\(item.content)\n\n---\nCaptured \(dateStr)\(appStr)"

        case .link:
            var previewBlock = ""
            if let lp = item.linkPreview {
                previewBlock += "\n"
                if let t = lp.title { previewBlock += "**\(t)**\n" }
                if let d = lp.description { previewBlock += "\(d)\n" }
            }
            body = "# \(item.displayTitle)\n\(previewBlock)\n\(item.content)\n\n---\nCaptured \(dateStr)\(appStr)"
        }

        let full = "<!-- TOPDAWG_NOTE \(metaJSON) -->\n\n\(body)\n"
        try? full.write(toFile: item.filePath, atomically: true, encoding: .utf8)
    }

    private func loadAll() {
        guard let files = try? FileManager.default
            .contentsOfDirectory(at: Self.storageDir,
                                  includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "md" }) else { return }

        let loaded: [NoteItem] = files.compactMap { url in
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return parseMetadata(from: raw)
        }.sorted { $0.createdAt > $1.createdAt }

        DispatchQueue.main.async { self.notes = loaded }
    }

    private func parseMetadata(from raw: String) -> NoteItem? {
        guard let open  = raw.range(of: "<!-- TOPDAWG_NOTE "),
              let close = raw.range(of: " -->", range: open.upperBound..<raw.endIndex)
        else { return nil }
        let jsonStr = String(raw[open.upperBound..<close.lowerBound])
        guard let data = jsonStr.data(using: .utf8),
              let item = try? decoder.decode(NoteItem.self, from: data) else { return nil }
        return item
    }

    // MARK: - Helpers

    private func newFilePath(suffix: String) -> String {
        let name = "\(Self.fileFormatter.string(from: Date()))_\(suffix).md"
        return Self.storageDir.appendingPathComponent(name).path
    }

    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
