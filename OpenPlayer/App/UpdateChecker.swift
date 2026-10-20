import AppKit
import OpenPlayerCore

/// Asks GitHub for the latest release and offers to open its download page when it is newer.
final class UpdateChecker {
    static let repository = "naazeri/open-player"
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!

    private static let lastCheckKey = "UpdateCheckLastDate"
    private static let skippedVersionKey = "UpdateCheckSkippedVersion"
    private let settings: SettingsStore
    private var isChecking = false

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Automatic check: at most once a day, silent unless a new version exists.
    func checkInBackgroundIfDue() {
        guard settings.value.checkForUpdates else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        check(userInitiated: false)
    }

    /// "Check for Updates…": always reports the result.
    func check(userInitiated: Bool) {
        guard !isChecking else { return }
        isChecking = true
        var request = URLRequest(url: Self.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenPlayer/\(AppPaths.appVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let release = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                if let release, status == 200 {
                    self.handle(release, userInitiated: userInitiated)
                } else if userInitiated {
                    let reason = error?.localizedDescription ?? (status == 404 ? "No release has been published yet." : "GitHub answered with status \(status).")
                    self.alert("Couldn't check for updates", reason)
                }
            }
        }.resume()
    }

    private func handle(_ release: Release, userInitiated: Bool) {
        guard let latest = AppVersion(release.tagName), let current = AppVersion(AppPaths.appVersion) else {
            if userInitiated { alert("Couldn't check for updates", "The release version “\(release.tagName)” is not readable.") }
            return
        }
        guard current < latest else {
            if userInitiated { alert("You're up to date", "Open Player \(current) is the latest version.") }
            return
        }
        if !userInitiated, UserDefaults.standard.string(forKey: Self.skippedVersionKey) == latest.description { return }

        let alert = NSAlert()
        alert.messageText = "Open Player \(latest) is available"
        var info = "You have version \(current)."
        if let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            info += "\n\n" + (notes.count > 600 ? String(notes.prefix(600)) + "…" : notes)
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if !userInitiated { alert.addButton(withTitle: "Skip This Version") }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.htmlURL.flatMap(URL.init(string:)) ?? Self.releasesPage)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(latest.description, forKey: Self.skippedVersionKey)
        default:
            break
        }
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String?
        let body: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
        }
    }
}
