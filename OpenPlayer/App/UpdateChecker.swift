import AppKit
import OpenPlayerCore
import Sparkle

/// In-app updates through Sparkle: checks the appcast published with each GitHub release about
/// once a day, then downloads, verifies (EdDSA signature), installs and relaunches on request.
final class UpdateChecker: NSObject, SPUUpdaterDelegate {
    static let repository = "naazeri/open-player"

    private var controller: SPUStandardUpdaterController!

    init(settings: SettingsStore) {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        setAutomaticChecks(settings.value.checkForUpdates)
        controller.startUpdater()
    }

    /// Follows Settings → Updates; Sparkle schedules the checks itself, also while the app runs
    /// in the background without a window.
    func setAutomaticChecks(_ enabled: Bool) {
        if controller.updater.automaticallyChecksForUpdates != enabled {
            controller.updater.automaticallyChecksForUpdates = enabled
        }
    }

    /// "Check for Updates…": always reports the result.
    func check() { controller.checkForUpdates(nil) }

    /// `OPEN_PLAYER_UPDATE_FEED` points at a local appcast for testing. Updates still need a valid
    /// signature from the release key, so this can't be used to install anything else.
    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["OPEN_PLAYER_UPDATE_FEED"]
    }
}
