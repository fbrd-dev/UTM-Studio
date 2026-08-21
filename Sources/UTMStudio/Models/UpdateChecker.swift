import Foundation

/// Checks GitHub's public releases API for a newer version than the one
/// currently running. Deliberately NOT a self-updater — it only ever offers
/// a link to the release page; downloading/installing stays a manual,
/// user-initiated step. See DEVELOPMENT.md for why (a real auto-updater
/// needs a signed-update-verification story, which is a meaningfully bigger
/// commitment than this app currently warrants).
enum UpdateChecker {
    /// Update this once the repo actually exists on GitHub, as "owner/repo".
    /// Until then, checks fail harmlessly (404 → silently no update found).
    static let githubRepo = "fbrd-dev/UTM-Studio"

    struct AvailableUpdate {
        let version: String
        let releaseURL: URL
    }

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// Fetches the latest GitHub release and returns it only if it's newer
    /// than the running app. Fails silently (returns nil) on any network,
    /// HTTP, or parsing error — a background version check must never be
    /// able to disrupt normal use of the app.
    static func checkForUpdate() async -> AvailableUpdate? {
        guard let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tagName = json["tag_name"] as? String,
            let htmlURLString = json["html_url"] as? String,
            let releaseURL = URL(string: htmlURLString)
        else {
            return nil
        }

        let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        guard isVersion(latestVersion, newerThan: currentVersion) else { return nil }
        return AvailableUpdate(version: latestVersion, releaseURL: releaseURL)
    }

    /// Numeric, component-by-component comparison (so "1.10.0" correctly
    /// beats "1.9.0"), not a naive string/lexicographic one.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}
