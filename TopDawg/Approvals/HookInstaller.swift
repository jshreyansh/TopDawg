import Foundation
import OSLog

/// Installs / updates / removes TopDawg's Claude Code hooks in `~/.claude/settings.json`.
///
/// Entries are identified by a `source=topdawg` query parameter in their URL, so we can
/// safely coexist with other hooks the user has configured and re-run idempotently.
struct HookInstaller {

    // MARK: - Paths

    static var settingsURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/settings.json")
    }

    // MARK: - Marker

    private static let marker = "source=topdawg"

    // MARK: - Public API

    struct HookURLs {
        let permission: String    // posted to for each PermissionRequest
        let notification: String  // posted to for each Notification
    }

    /// Patch settings.json so PermissionRequest + Notification hooks point at `urls`.
    /// Returns a short human-readable summary ("installed" / "updated" / "unchanged").
    static func install(urls: HookURLs) throws -> String {
        let url = settingsURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var root: [String: Any] = loadRoot(at: url) ?? [:]
        var hooks: [String: Any] = root["hooks"] as? [String: Any] ?? [:]

        let beforePermission = hooks["PermissionRequest"] as? [[String: Any]]
        let beforeNotification = hooks["Notification"] as? [[String: Any]]

        hooks["PermissionRequest"] = patch(
            array: beforePermission,
            withTopDawgURL: urls.permission
        )
        hooks["Notification"] = patch(
            array: beforeNotification,
            withTopDawgURL: urls.notification
        )
        root["hooks"] = hooks

        // Pretty-print so the file stays human-editable.
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )

        // Only write if changed (so file mtime stays meaningful).
        if let existing = try? Data(contentsOf: url), existing == data {
            return "unchanged"
        }

        // Write atomically via temp file, so a mid-write crash never nukes settings.
        let tmp = url.appendingPathExtension("topdawg.tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)

        return (beforePermission == nil && beforeNotification == nil) ? "installed" : "updated"
    }

    /// Remove any TopDawg-marked hook entries. Leaves everything else untouched.
    @discardableResult
    static func uninstall() throws -> String {
        let url = settingsURL
        guard var root = loadRoot(at: url) else { return "nothing to remove" }
        guard var hooks = root["hooks"] as? [String: Any] else { return "nothing to remove" }

        var changed = false
        for event in ["PermissionRequest", "Notification"] {
            guard let array = hooks[event] as? [[String: Any]] else { continue }
            let filtered = array.compactMap { entry -> [String: Any]? in
                guard var innerHooks = entry["hooks"] as? [[String: Any]] else { return entry }
                let kept = innerHooks.filter { !isTopDawg($0) }
                if kept.count == innerHooks.count { return entry }
                changed = true
                if kept.isEmpty { return nil }
                innerHooks = kept
                var copy = entry
                copy["hooks"] = innerHooks
                return copy
            }
            if filtered.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = filtered
            }
        }

        if !changed { return "nothing to remove" }
        root["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
        return "removed"
    }

    // MARK: - Internals

    private static func loadRoot(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Take the existing array for a hook event, strip any TopDawg-marked entries,
    /// then append a single new TopDawg entry with `url`.
    private static func patch(
        array: [[String: Any]]?,
        withTopDawgURL url: String
    ) -> [[String: Any]] {
        var out = (array ?? []).compactMap { entry -> [String: Any]? in
            guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return entry }
            let kept = innerHooks.filter { !isTopDawg($0) }
            if kept.isEmpty { return nil }
            var copy = entry
            copy["hooks"] = kept
            return copy
        }
        out.append([
            "matcher": "",
            "hooks": [
                [
                    "type": "http",
                    "url": url
                ] as [String: Any]
            ]
        ])
        return out
    }

    private static func isTopDawg(_ hook: [String: Any]) -> Bool {
        guard let url = hook["url"] as? String else { return false }
        return url.contains(marker) || url.contains("127.0.0.1") && url.contains("topdawg")
    }
}
