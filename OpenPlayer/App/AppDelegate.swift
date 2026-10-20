import AppKit
import Combine
import OpenPlayerCore

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let settings = SettingsStore()
    private var library: LibraryStore!
    private var player: PlayerController!
    private var backup: BackupController!
    private var updates: UpdateChecker!
    private var settingsWindow: SettingsWindowController?
    private var playlistPanel: PlaylistPanelController?
    private var bookmarkManager: BookmarkManagerWindowController?
    private var pendingURLs: [URL] = []
    private var menuSubscription: AnyCancellable?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        library = openLibrary()
        backup = BackupController(settings: settings, library: library)
        player = PlayerController(settings: settings, library: library)
        player.onShowSettings = { [weak self] in self?.showSettings(nil) }
        player.onTogglePlaylist = { [weak self] in self?.togglePlaylist(nil) }
        player.onShowBookmarkManager = { [weak self] in self?.showBookmarkManager(nil) }
        backup.onImported = { [weak self] in self?.player.bookmarks.onChange?() }

        updates = UpdateChecker(settings: settings)
        // Rebuilt when shortcuts or seek steps change, so menus always show the current keys.
        menuSubscription = settings.$value
            .map { [$0.keyOverrides as AnyHashable, $0.seekSteps as AnyHashable] }
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { NSApp.mainMenu = MainMenuBuilder.build(target: self, settings: self.settings.value) }
            }
        player.showWindow()
        NSApp.activate(ignoringOtherApps: true)

        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let urls = pendingURLs + arguments
        pendingURLs = []
        if !urls.isEmpty { player.open(urls) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.updates.checkInBackgroundIfDue() }
    }

    private func openLibrary() -> LibraryStore {
        do {
            return try LibraryStore(path: AppPaths.libraryFile.path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "The bookmark database could not be opened"
            alert.informativeText = "\(error)\n\nBookmarks will not be saved in this session. File: \(AppPaths.libraryFile.path)"
            alert.runModal()
            return try! LibraryStore(path: ":memory:")
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let player {
            player.open(urls)
            player.showWindow()
        } else {
            pendingURLs += urls
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        player?.showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        player?.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Menu actions

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Player shortcuts shown in menus are display-only: never let a key press fire them here.
        if item.action == #selector(performPlayerAction(_:)), item.tag != MenuShortcuts.nativeTag,
           MenuShortcuts.isMatchingKeyEquivalent {
            return false
        }
        return true
    }

    @objc func performPlayerAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = PlayerAction(rawValue: raw) else { return }
        player.perform(action)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(store: settings, backup: backup) }
        settingsWindow?.show()
    }

    @objc func showShortcuts(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(store: settings, backup: backup) }
        settingsWindow?.show(tab: .shortcuts)
    }

    @objc func togglePlaylist(_ sender: Any?) {
        if playlistPanel == nil {
            playlistPanel = PlaylistPanelController(model: player.playlist) { [weak self] index in
                self?.player.play(index: index)
            }
        }
        playlistPanel?.toggle(relativeTo: player.windowController.window)
    }

    @objc func showBookmarkManager(_ sender: Any?) {
        if bookmarkManager == nil {
            bookmarkManager = BookmarkManagerWindowController(service: player.bookmarks) { [weak self] bookmark in
                self?.player.jump(to: bookmark)
                self?.player.showWindow()
            }
        }
        bookmarkManager?.showWindow(nil)
    }

    @objc func checkForUpdates(_ sender: Any?) { updates.check(userInitiated: true) }

    @objc func openProjectPage(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateChecker.repository)")!)
    }

    @objc func exportBackup(_ sender: Any?) { backup.export() }
    @objc func importBackup(_ sender: Any?) { backup.importBackup() }
}
