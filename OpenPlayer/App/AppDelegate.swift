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
    private var menuSubscription: AnyCancellable?
    private var launchFinished = false
    /// Files the app was launched with, to ignore AppKit delivering them a second time.
    private var launchFiles: Set<URL> = []

    static func main() {
        // Otherwise AppKit also turns command-line paths into an "open" event and the file loads twice.
        // Also: no macOS window restoration (the app reopens files itself), which otherwise asks
        // "reopen windows?" after a crash.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO", "ApplePersistenceIgnoreState": "YES"])
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    // Launch order matters for speed: the player (and the file it should play) is created as early as
    // possible — at will-finish for command-line files, at the open event for files opened from
    // Finder — so mpv starts reading the file while AppKit and the rest of the app finish launching.

    func applicationWillFinishLaunching(_ notification: Notification) {
        Signpost.event("willFinishLaunching")
        library = openLibrary()
        backup = BackupController(settings: settings, library: library)
        backup.onImported = { [weak self] in self?.player?.bookmarks.onChange?() }

        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !arguments.isEmpty { makePlayer(initialURLs: arguments) }
    }

    private func makePlayer(initialURLs: [URL]) {
        launchFiles = Set(initialURLs.map(\.standardizedFileURL))
        player = PlayerController(settings: settings, library: library, initialURLs: initialURLs)
        player.onShowSettings = { [weak self] in self?.showSettings(nil) }
        player.onTogglePlaylist = { [weak self] in self?.togglePlaylist(nil) }
        player.onShowBookmarkManager = { [weak self] in self?.showBookmarkManager(nil) }
        player.onWindowClosed = { [weak self] in self?.playlistPanel?.window?.orderOut(nil) }
        // mpv can only draw once the video view is on screen; don't wait for the rest of the launch.
        if !initialURLs.isEmpty { player.showWindow() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Signpost.event("didFinishLaunching")
        if player == nil { makePlayer(initialURLs: []) }

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
        launchFinished = true
    }

    /// Also covers launch. The check itself runs at most once a day, which matters now that the
    /// app can stay running in the background for days.
    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.updates?.checkInBackgroundIfDue() }
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
        Signpost.event("openEvent")
        guard let player else {
            // Opened from Finder while launching: start the file before the rest of the launch.
            makePlayer(initialURLs: urls)
            return
        }
        if !launchFinished, Set(urls.map(\.standardizedFileURL)) == launchFiles { return }
        player.open(urls)
        player.showWindow()
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
