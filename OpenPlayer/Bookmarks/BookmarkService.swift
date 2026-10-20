import AppKit
import Foundation
import OpenPlayerCore

/// Bookmarks in the central database, kept in sync with PotPlayer `.pbf` files next to the media.
final class BookmarkService {
    let store: LibraryStore
    private let settings: SettingsStore
    /// Called after any bookmark change (UI refresh).
    var onChange: (() -> Void)?

    init(store: LibraryStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
    }

    static func key(for url: URL) -> String { url.standardizedFileURL.path }

    func bookmarks(for url: URL) -> [Bookmark] { store.bookmarks(for: Self.key(for: url)) }

    func bookmarkedFiles() -> [BookmarkedFile] { store.bookmarkedFiles() }

    /// Reads the `.pbf` next to `url` (if any). The `.pbf` wins when it differs from the database.
    func syncFromPBF(for url: URL) {
        guard let pbfURL = PBFLocator.existing(for: url), let data = try? Data(contentsOf: pbfURL) else { return }
        let document = PBFCodec.decode(data)
        let current = bookmarks(for: url).map(\.pbfEntry)
        guard let resolved = BookmarkSync.resolve(database: current, pbf: document.entries) else { return }
        let modified = (try? pbfURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        do {
            try store.replaceBookmarks(path: Self.key(for: url), with: resolved, date: modified)
            onChange?()
        } catch {
            NSLog("Bookmark sync failed: %@", error.localizedDescription)
        }
    }

    /// Returns a warning when the `.pbf` could not be updated.
    @discardableResult
    func add(url: URL, seconds: Double, thumbnail: Data?) throws -> (Bookmark, String?) {
        let bookmark = try store.addBookmark(path: Self.key(for: url), positionMs: Int64((seconds * 1000).rounded()),
                                             thumbnail: thumbnail)
        let warning = writePBF(for: url, allowCreate: settings.value.createPBFFiles)
        onChange?()
        return (bookmark, warning)
    }

    @discardableResult
    func rename(_ bookmark: Bookmark, to title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        try? store.renameBookmark(id: bookmark.id, to: trimmed)
        let warning = writePBF(for: URL(fileURLWithPath: bookmark.path), allowCreate: false)
        onChange?()
        return warning
    }

    @discardableResult
    func delete(_ bookmark: Bookmark) -> String? {
        try? store.deleteBookmark(id: bookmark.id)
        let warning = writePBF(for: URL(fileURLWithPath: bookmark.path), allowCreate: false)
        onChange?()
        return warning
    }

    @discardableResult
    func deleteAll(for path: String) -> String? {
        try? store.deleteAllBookmarks(path: path)
        let warning = writePBF(for: URL(fileURLWithPath: path), allowCreate: false)
        onChange?()
        return warning
    }

    /// Rewrites the `.pbf` (existing one, or a new one when allowed). Other sections in it are preserved.
    @discardableResult
    private func writePBF(for url: URL, allowCreate: Bool) -> String? {
        let existing = PBFLocator.existing(for: url)
        guard let target = existing ?? (allowCreate ? PBFLocator.preferred(for: url) : nil) else { return nil }
        var document = existing.flatMap { try? Data(contentsOf: $0) }.map(PBFCodec.decode) ?? PBFDocument()
        document.entries = bookmarks(for: url).map(\.pbfEntry)
        do {
            try PBFCodec.encode(document).write(to: target)
            return nil
        } catch {
            return "Couldn't update \(target.lastPathComponent) (the drive may be read-only)"
        }
    }

    /// Creates the missing thumbnails of a video's bookmarks (e.g. ones that came from a `.pbf`), one at a time.
    func generateMissingThumbnails(for url: URL, limit: Int = 30) {
        let missing = bookmarks(for: url).filter { $0.thumbnail == nil }.prefix(limit)
        for bookmark in missing { generateThumbnail(for: bookmark) }
    }

    /// Fills in a thumbnail in the background (video only) and updates the `.pbf` afterwards.
    func generateThumbnail(for bookmark: Bookmark) {
        let url = URL(fileURLWithPath: bookmark.path)
        ThumbnailGenerator.generate(for: url, at: bookmark.seconds) { [weak self] data in
            guard let self, let data else { return }
            try? self.store.setThumbnail(id: bookmark.id, data: data)
            self.writePBF(for: url, allowCreate: false)
            self.onChange?()
        }
    }
}
