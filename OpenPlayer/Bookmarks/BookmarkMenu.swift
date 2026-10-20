import AppKit
import OpenPlayerCore

/// Builds the PotPlayer style "H" menu: files (newest bookmark change first, current file bold),
/// each with a submenu of its bookmarks in time order. Right-click a bookmark to rename or delete it.
final class BookmarkMenuBuilder: NSObject {
    struct Handlers {
        var jump: (Bookmark) -> Void
        var rename: (Bookmark) -> Void
        var delete: (Bookmark) -> Void
        var deleteAll: (BookmarkedFile) -> Void
        var addHere: (() -> Void)?
        var manage: () -> Void
    }

    private let handlers: Handlers
    private var actions: [ObjectIdentifier: () -> Void] = [:]

    init(handlers: Handlers) {
        self.handlers = handlers
    }

    func makeMenu(files: [BookmarkedFile], currentPath: String?, keyMap: KeyMap = KeyMap()) -> NSMenu {
        let menu = NSMenu(title: "Bookmarks")
        menu.autoenablesItems = false

        let add = item("Add Bookmark") { [handlers] in handlers.addHere?() }
        MenuShortcuts.show(.addBookmark, on: add, keyMap: keyMap)
        add.isEnabled = handlers.addHere != nil
        menu.addItem(add)
        let manage = item("Manage Bookmarks…") { [handlers] in handlers.manage() }
        manage.keyEquivalent = "b"
        manage.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(manage)
        menu.addItem(.separator())

        if files.isEmpty {
            let empty = NSMenuItem(title: "No bookmarks yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for file in files {
            let fileItem = NSMenuItem(title: file.fileName, action: nil, keyEquivalent: "")
            let exists = FileManager.default.fileExists(atPath: file.path)
            let isCurrent = file.path == currentPath
            let font = isCurrent ? NSFont.menuFont(ofSize: 0).bold : NSFont.menuFont(ofSize: 0)
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if !exists { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
            fileItem.attributedTitle = NSAttributedString(string: file.fileName, attributes: attributes)
            // Only for missing files: a tooltip would otherwise cover the first bookmark of the submenu.
            if !exists { fileItem.toolTip = "\(file.path)\n(file not found — is the drive connected?)" }
            fileItem.image = NSImage(systemSymbolName: MediaTypes.kind(of: file.url) == .audio ? "music.note" : "film",
                                     accessibilityDescription: nil)

            let submenu = NSMenu(title: file.fileName)
            submenu.autoenablesItems = false
            for bookmark in file.bookmarks {
                let bookmarkItem = NSMenuItem(title: bookmark.displayTitle, action: nil, keyEquivalent: "")
                let view = BookmarkMenuItemView(bookmark: bookmark)
                view.onSelect = { [handlers] in handlers.jump(bookmark) }
                view.onContextMenu = { [weak self] in self?.showContextMenu(for: bookmark, file: file) }
                bookmarkItem.view = view
                submenu.addItem(bookmarkItem)
            }
            fileItem.submenu = submenu
            menu.addItem(fileItem)
        }
        return menu
    }

    private func showContextMenu(for bookmark: Bookmark, file: BookmarkedFile) {
        let menu = NSMenu()
        menu.addItem(item("Go to \(TimeFormat.long(bookmark.seconds))") { [handlers] in handlers.jump(bookmark) })
        menu.addItem(.separator())
        menu.addItem(item("Rename…") { [handlers] in handlers.rename(bookmark) })
        menu.addItem(item("Delete") { [handlers] in handlers.delete(bookmark) })
        menu.addItem(.separator())
        menu.addItem(item("Delete All Bookmarks of “\(file.fileName)”") { [handlers] in handlers.deleteAll(file) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        actions[ObjectIdentifier(item)] = action
        return item
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        actions[ObjectIdentifier(sender)]?()
    }
}

/// A bookmark row inside the H submenu: thumbnail + "Bookmark 1 — 00:03:20".
/// Custom view so it can react to right clicks, which plain menu items cannot.
final class BookmarkMenuItemView: NSView {
    private static let height: CGFloat = 44
    private static let thumbSize = NSSize(width: 64, height: 36)

    let bookmark: Bookmark
    var onSelect: (() -> Void)?
    var onContextMenu: (() -> Void)?

    private let thumbnail: NSImage?
    private var hovering = false
    private var contextMenuRequested = false

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        thumbnail = bookmark.thumbnail.flatMap(NSImage.init(data:))
        let textWidth = (bookmark.displayTitle as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
        super.init(frame: NSRect(x: 0, y: 0, width: max(240, 20 + Self.thumbSize.width + 12 + textWidth + 24), height: Self.height))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    private var isHighlighted: Bool { hovering || enclosingMenuItem?.isHighlighted == true }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isHighlighted
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
        }

        let thumbRect = NSRect(x: 14, y: (bounds.height - Self.thumbSize.height) / 2,
                               width: Self.thumbSize.width, height: Self.thumbSize.height)
        if let thumbnail {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: thumbRect, xRadius: 3, yRadius: 3).addClip()
            thumbnail.draw(in: aspectFill(thumbnail.size, in: thumbRect))
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: thumbRect, xRadius: 3, yRadius: 3).fill()
            let icon = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: nil)
            icon?.draw(in: thumbRect.insetBy(dx: 24, dy: 10))
        }

        let color = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let text = NSAttributedString(string: bookmark.displayTitle,
                                      attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: color])
        let size = text.size()
        text.draw(at: NSPoint(x: thumbRect.maxX + 12, y: (bounds.height - size.height) / 2))
    }

    private func aspectFill(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    override func mouseUp(with event: NSEvent) {
        // Menus also report the right button's release here; that must not jump.
        guard event.type == .leftMouseUp, !contextMenuRequested else { return }
        if event.modifierFlags.contains(.control) { return showContextMenu() }
        let action = onSelect
        closeMenus()
        DispatchQueue.main.async { action?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu()
    }

    private func showContextMenu() {
        guard !contextMenuRequested else { return }
        contextMenuRequested = true
        let action = onContextMenu
        closeMenus()
        // Show the context menu once the bookmark menu has finished closing.
        DispatchQueue.main.async { action?() }
    }

    private func closeMenus() {
        var menu = enclosingMenuItem?.menu
        while let current = menu {
            current.cancelTrackingWithoutAnimation()
            menu = current.supermenu
        }
    }
}

extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
