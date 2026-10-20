import AppKit
import OpenPlayerCore

/// The menu bar. Player actions carry no key equivalents: the player's key handler owns those keys,
/// so each item shows its default shortcut as a tooltip instead.
enum MainMenuBuilder {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(target)))
        main.addItem(submenu(fileMenu(target)))
        main.addItem(submenu(playbackMenu(target)))
        main.addItem(submenu(audioSubtitleMenu(target)))
        main.addItem(submenu(bookmarksMenu(target)))
        main.addItem(submenu(windowMenu(target)))
        main.addItem(submenu(helpMenu(target)))
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func action(_ action: PlayerAction, _ target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem(title: action.title(), action: #selector(AppDelegate.performPlayerAction(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = action.rawValue
        if let combo = DefaultKeyMap.bindings[action]?.first {
            item.toolTip = "Default shortcut: \(combo)"
        }
        return item
    }

    private static func item(_ title: String, _ selector: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private static func appMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Open Player")
        menu.addItem(item("About Open Player", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)), target: target))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: target))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide Open Player", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Open Player", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        let open = action(.openFile, target)
        open.keyEquivalent = "o"
        open.keyEquivalentModifierMask = .command
        menu.addItem(open)
        let folder = action(.openFolder, target)
        folder.keyEquivalent = "o"
        folder.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(folder)

        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        recent.submenu = recentMenu
        menu.addItem(recent)

        menu.addItem(.separator())
        menu.addItem(action(.closePlayback, target))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Export Backup…", #selector(AppDelegate.exportBackup(_:)), target: target))
        menu.addItem(item("Import Backup…", #selector(AppDelegate.importBackup(_:)), target: target))
        return menu
    }

    private static func playbackMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Playback")
        for playerAction: PlayerAction in [.playPause, .previousFile, .nextFile] {
            menu.addItem(action(playerAction, target))
        }
        menu.addItem(.separator())
        for playerAction: PlayerAction in [.seekBackward1, .seekForward1, .seekBackward2, .seekForward2,
                                           .previousFrame, .nextFrame, .jumpToStart, .jumpToTime] {
            menu.addItem(action(playerAction, target))
        }
        menu.addItem(.separator())
        for playerAction: PlayerAction in [.speedUp, .speedDown, .speedReset] {
            menu.addItem(action(playerAction, target))
        }
        menu.addItem(.separator())
        menu.addItem(action(.saveFrame, target))
        return menu
    }

    private static func audioSubtitleMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Audio & Subtitles")
        for playerAction: PlayerAction in [.volumeUp, .volumeDown, .mute, .cycleAudio, .audioDelayDown, .audioDelayUp,
                                           .audioDelayReset] {
            menu.addItem(action(playerAction, target))
        }
        menu.addItem(.separator())
        for playerAction: PlayerAction in [.loadSubtitle, .toggleSubtitles, .cycleSubtitle, .subtitleDelayDown,
                                           .subtitleDelayUp, .subtitleDelayReset, .subtitleSizeUp, .subtitleSizeDown] {
            menu.addItem(action(playerAction, target))
        }
        return menu
    }

    private static func bookmarksMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Bookmarks")
        menu.addItem(action(.addBookmark, target))
        menu.addItem(action(.showBookmarks, target))
        menu.addItem(item("Manage Bookmarks…", #selector(AppDelegate.showBookmarkManager(_:)), "b", [.command, .shift],
                          target: target))
        return menu
    }

    private static func windowMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Window")
        let fullscreen = action(.toggleFullscreen, target)
        fullscreen.keyEquivalent = "f"
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullscreen)
        for playerAction: PlayerAction in [.windowSizeHalf, .windowSizeNormal, .windowSizeOneAndHalf,
                                           .windowSizeDouble, .stayOnTop, .showInfo] {
            menu.addItem(action(playerAction, target))
        }
        menu.addItem(.separator())
        menu.addItem(item("Playlist", #selector(AppDelegate.togglePlaylist(_:)), "l", [.command, .option], target: target))
        menu.addItem(.separator())
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        NSApp.windowsMenu = menu
        return menu
    }

    private static func helpMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Keyboard Shortcuts", #selector(AppDelegate.showShortcuts(_:)), "/", [.command], target: target))
        menu.addItem(item("Open Player on GitHub", #selector(AppDelegate.openProjectPage(_:)), target: target))
        NSApp.helpMenu = menu
        return menu
    }
}
