import Combine
import Foundation
import OpenPlayerCore

enum AppPaths {
    static let supportDirectory: URL = {
        #if DEBUG
        // Lets automated checks run against a throwaway library: OPEN_PLAYER_DATA_DIR=/some/folder
        if let custom = ProcessInfo.processInfo.environment["OPEN_PLAYER_DATA_DIR"] {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Open Player", isDirectory: true)
        // The app was first called "Reza Player"; carry its settings and bookmarks over once.
        let previous = base.appendingPathComponent("Reza Player", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: previous.path) {
            try? FileManager.default.moveItem(at: previous, to: url)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    static var libraryFile: URL { supportDirectory.appendingPathComponent("library.sqlite") }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

/// Holds the settings, saves them shortly after every change and publishes updates.
final class SettingsStore: ObservableObject {
    @Published var value: AppSettings {
        didSet { if value != oldValue { scheduleSave() } }
    }

    private let url: URL
    private var saveWork: DispatchWorkItem?

    init(url: URL = AppPaths.settingsFile) {
        self.url = url
        value = SettingsFile.load(from: url)
    }

    func update(_ change: (inout AppSettings) -> Void) {
        var copy = value
        change(&copy)
        value = copy
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        do {
            try SettingsFile.save(value, to: url)
        } catch {
            NSLog("Saving settings failed: %@", error.localizedDescription)
        }
    }
}
