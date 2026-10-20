import AppKit
import OpenPlayerCore
import UniformTypeIdentifiers

/// Export/import of settings + library as one JSON file.
final class BackupController {
    private let settings: SettingsStore
    private let library: LibraryStore
    var onImported: (() -> Void)?

    init(settings: SettingsStore, library: LibraryStore) {
        self.settings = settings
        self.library = library
    }

    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        panel.nameFieldStringValue = "Open Player Backup \(date).json"
        panel.message = "Export settings, shortcuts and bookmarks"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try BackupCodec.encode(settings: settings.value, library: library.snapshot(),
                                              appVersion: AppPaths.appVersion)
            try data.write(to: url, options: .atomic)
            inform("Backup exported", "Saved to \(url.lastPathComponent).")
        } catch {
            inform("Export failed", error.localizedDescription, style: .warning)
        }
    }

    func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .data]
        panel.message = "Choose a Open Player backup file"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let confirm = NSAlert()
        confirm.messageText = "Replace current settings and bookmarks?"
        confirm.informativeText = "Everything in “\(url.lastPathComponent)” will replace your current settings, shortcuts, bookmarks and resume positions."
        confirm.addButton(withTitle: "Import")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        do {
            let data = try Data(contentsOf: url)
            let backup = try BackupCodec.decode(data)
            try library.restore(backup.library)
            settings.value = backup.settings
            settings.saveNow()
            onImported?()
            let count = backup.library.files.reduce(0) { $0 + $1.bookmarks.count }
            inform("Backup imported", "\(count) bookmarks in \(backup.library.files.count) files were restored.")
        } catch {
            inform("Import failed", error.localizedDescription, style: .warning)
        }
    }

    private func inform(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.runModal()
    }
}
