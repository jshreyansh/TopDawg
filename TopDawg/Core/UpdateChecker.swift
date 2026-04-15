import Foundation
import AppKit
import SwiftUI

final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    // ── Configure these for your GitHub repo ──
    // Auto-updater is disabled in AppDelegate; these are placeholders. Update them
    // (and re-enable the launch check) only after you set up your own release pipeline.
    static let repoOwner = "unset"
    static let repoName  = "TopDawg"

    @Published var latestVersion: String?
    @Published var downloadURL: URL?
    @Published var releaseNotes: String?
    @Published var isChecking = false
    @Published var updateAvailable = false
    @Published var lastChecked: Date?
    @Published var lastError: String?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    // MARK: - Check

    func check(silent: Bool = false) {
        guard !isChecking else { return }

        DispatchQueue.main.async { self.isChecking = true; self.lastError = nil }

        let urlString = "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isChecking = false
                self.lastChecked = Date()

                if let error = error {
                    if !silent { self.lastError = error.localizedDescription }
                    return
                }

                guard let data = data,
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    if !silent { self.lastError = "Could not reach GitHub." }
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    if !silent { self.lastError = "Invalid response." }
                    return
                }

                // Parse release info
                let tagName = (json["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let notes   = json["body"] as? String
                let htmlURL = json["html_url"] as? String

                // Find .app.zip or .dmg asset
                var assetURL: URL? = nil
                if let assets = json["assets"] as? [[String: Any]] {
                    for asset in assets {
                        if let name = asset["name"] as? String,
                           let dl   = asset["browser_download_url"] as? String,
                           (name.hasSuffix(".zip") || name.hasSuffix(".dmg")) {
                            assetURL = URL(string: dl)
                            break
                        }
                    }
                }

                self.latestVersion = tagName
                self.releaseNotes  = notes
                self.downloadURL   = assetURL ?? (htmlURL.flatMap { URL(string: $0) })

                // Compare versions
                let comparison = self.compareVersions(self.currentVersion, tagName)
                self.updateAvailable = comparison == .orderedAscending

                if !silent && !self.updateAvailable {
                    self.lastError = nil // Clear — will show "up to date" in UI
                }

                // Show alert if update is available and not silent
                if self.updateAvailable && !silent {
                    self.showUpdateAlert(newVersion: tagName, notes: notes)
                }
            }
        }.resume()
    }

    // MARK: - Auto-check on launch

    func checkOnLaunchIfNeeded() {
        // Check at most once per 6 hours
        let key = "cn.lastUpdateCheck"
        let lastCheck = UserDefaults.standard.double(forKey: key)
        let sixHours: TimeInterval = 6 * 3600
        guard Date().timeIntervalSince1970 - lastCheck > sixHours else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        check(silent: true)
    }

    // MARK: - Open download

    func openDownload() {
        guard let url = downloadURL else {
            // Fallback: open the releases page
            if let page = URL(string: "https://github.com/\(Self.repoOwner)/\(Self.repoName)/releases/latest") {
                NSWorkspace.shared.open(page)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Alert

    private func showUpdateAlert(newVersion: String, notes: String?) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "TopDawg \(newVersion) is available (you have \(currentVersion)).\(notes.map { "\n\n\($0.prefix(300))" } ?? "")"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            openDownload()
        }
    }

    // MARK: - Version comparison

    private func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count  = max(aParts.count, bParts.count)

        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }
}
