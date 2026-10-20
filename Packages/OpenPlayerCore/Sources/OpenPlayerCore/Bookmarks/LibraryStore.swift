import Foundation

public struct Bookmark: Hashable, Identifiable, Sendable {
    public var id: Int64
    public var path: String
    public var positionMs: Int64
    public var title: String
    public var thumbnail: Data?
    public var createdAt: Date

    public var seconds: Double { Double(positionMs) / 1000 }

    /// "Bookmark 1 — 00:03:20"
    public var displayTitle: String { "\(title) — \(TimeFormat.long(seconds))" }

    public var pbfEntry: PBFEntry { PBFEntry(positionMs: positionMs, title: title, thumbnailJPEG: thumbnail) }
}

public struct BookmarkedFile: Hashable, Sendable {
    public var path: String
    /// Last time a bookmark of this file was added, renamed, deleted or synced from a `.pbf`.
    public var updatedAt: Date
    /// Sorted by position.
    public var bookmarks: [Bookmark]

    public var url: URL { URL(fileURLWithPath: path) }
    public var fileName: String { url.lastPathComponent }
}

/// Central store for bookmarks and resume positions.
public final class LibraryStore {
    private let db: SQLiteDatabase
    private static let schemaVersion = 1

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try migrate()
    }

    private func migrate() throws {
        let version = db.userVersion
        if version < 1 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS media_files (
                        id INTEGER PRIMARY KEY,
                        path TEXT NOT NULL UNIQUE,
                        bookmarks_updated_at REAL NOT NULL
                    )
                    """)
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS bookmarks (
                        id INTEGER PRIMARY KEY,
                        file_id INTEGER NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
                        position_ms INTEGER NOT NULL,
                        title TEXT NOT NULL,
                        thumbnail BLOB,
                        created_at REAL NOT NULL
                    )
                    """)
                try db.execute("CREATE INDEX IF NOT EXISTS bookmarks_file ON bookmarks(file_id)")
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS playback_positions (
                        path TEXT PRIMARY KEY,
                        position REAL NOT NULL,
                        duration REAL,
                        updated_at REAL NOT NULL
                    )
                    """)
            }
        }
        // Future schema changes go here as `if version < 2 { ... }`.
        // Only write when it changes: a write at every launch would delay the first file.
        if version != Self.schemaVersion { db.userVersion = Self.schemaVersion }
    }

    // MARK: Bookmarks

    public func bookmarks(for path: String) -> [Bookmark] {
        let rows = (try? db.query("""
            SELECT b.id, b.position_ms, b.title, b.thumbnail, b.created_at
            FROM bookmarks b JOIN media_files f ON f.id = b.file_id
            WHERE f.path = ? ORDER BY b.position_ms, b.id
            """, [.text(path)])) ?? []
        return rows.map { bookmark(from: $0, path: path) }
    }

    /// Every file with at least one bookmark, most recently changed first.
    public func bookmarkedFiles() -> [BookmarkedFile] {
        let files = (try? db.query("""
            SELECT f.path, f.bookmarks_updated_at FROM media_files f
            WHERE EXISTS (SELECT 1 FROM bookmarks b WHERE b.file_id = f.id)
            ORDER BY f.bookmarks_updated_at DESC, f.id DESC
            """)) ?? []
        return files.compactMap { row in
            guard let path = row["path"]?.string else { return nil }
            let updated = Date(timeIntervalSince1970: row["bookmarks_updated_at"]?.double ?? 0)
            return BookmarkedFile(path: path, updatedAt: updated, bookmarks: bookmarks(for: path))
        }
    }

    /// Adds a bookmark. Without a title it is named "Bookmark N" like PotPlayer.
    @discardableResult
    public func addBookmark(path: String, positionMs: Int64, title: String? = nil, thumbnail: Data? = nil,
                            date: Date = Date()) throws -> Bookmark {
        var result: Bookmark?
        try db.transaction {
            let fileID = try touchFile(path, date: date)
            let count = try db.query("SELECT COUNT(*) AS n FROM bookmarks WHERE file_id = ?", [.integer(fileID)])
                .first?["n"]?.int64 ?? 0
            let name = title ?? "Bookmark \(count + 1)"
            try db.execute(
                "INSERT INTO bookmarks (file_id, position_ms, title, thumbnail, created_at) VALUES (?, ?, ?, ?, ?)",
                [.integer(fileID), .integer(positionMs), .text(name), thumbnail.map(SQLValue.blob) ?? .null,
                 .real(date.timeIntervalSince1970)]
            )
            result = Bookmark(id: db.lastInsertRowID, path: path, positionMs: positionMs, title: name,
                              thumbnail: thumbnail, createdAt: date)
        }
        return result!
    }

    public func renameBookmark(id: Int64, to title: String, date: Date = Date()) throws {
        try db.transaction {
            try db.execute("UPDATE bookmarks SET title = ? WHERE id = ?", [.text(title), .integer(id)])
            try touchFile(ofBookmark: id, date: date)
        }
    }

    /// Thumbnails arrive after the bookmark is created; this is not a user change, so the file order stays.
    public func setThumbnail(id: Int64, data: Data?) throws {
        try db.execute("UPDATE bookmarks SET thumbnail = ? WHERE id = ?", [data.map(SQLValue.blob) ?? .null, .integer(id)])
    }

    public func deleteBookmark(id: Int64, date: Date = Date()) throws {
        try db.transaction {
            try touchFile(ofBookmark: id, date: date)
            try db.execute("DELETE FROM bookmarks WHERE id = ?", [.integer(id)])
            try removeEmptyFiles()
        }
    }

    public func deleteAllBookmarks(path: String) throws {
        try db.execute("DELETE FROM media_files WHERE path = ?", [.text(path)])
    }

    /// Replaces a file's bookmarks (used when its `.pbf` wins a conflict).
    public func replaceBookmarks(path: String, with entries: [PBFEntry], date: Date = Date()) throws {
        try db.transaction {
            let fileID = try touchFile(path, date: date)
            try db.execute("DELETE FROM bookmarks WHERE file_id = ?", [.integer(fileID)])
            for entry in entries {
                try db.execute(
                    "INSERT INTO bookmarks (file_id, position_ms, title, thumbnail, created_at) VALUES (?, ?, ?, ?, ?)",
                    [.integer(fileID), .integer(entry.positionMs), .text(entry.title),
                     entry.thumbnailJPEG.map(SQLValue.blob) ?? .null, .real(date.timeIntervalSince1970)]
                )
            }
            try removeEmptyFiles()
        }
    }

    @discardableResult
    private func touchFile(_ path: String, date: Date) throws -> Int64 {
        try db.execute("""
            INSERT INTO media_files (path, bookmarks_updated_at) VALUES (?, ?)
            ON CONFLICT(path) DO UPDATE SET bookmarks_updated_at = excluded.bookmarks_updated_at
            """, [.text(path), .real(date.timeIntervalSince1970)])
        return try db.query("SELECT id FROM media_files WHERE path = ?", [.text(path)]).first?["id"]?.int64 ?? 0
    }

    private func touchFile(ofBookmark id: Int64, date: Date) throws {
        try db.execute("""
            UPDATE media_files SET bookmarks_updated_at = ?
            WHERE id = (SELECT file_id FROM bookmarks WHERE id = ?)
            """, [.real(date.timeIntervalSince1970), .integer(id)])
    }

    private func removeEmptyFiles() throws {
        try db.execute("DELETE FROM media_files WHERE NOT EXISTS (SELECT 1 FROM bookmarks b WHERE b.file_id = media_files.id)")
    }

    private func bookmark(from row: [String: SQLValue], path: String) -> Bookmark {
        Bookmark(
            id: row["id"]?.int64 ?? 0,
            path: path,
            positionMs: row["position_ms"]?.int64 ?? 0,
            title: row["title"]?.string ?? "",
            thumbnail: row["thumbnail"]?.data.flatMap { $0.isEmpty ? nil : $0 },
            createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0)
        )
    }

    // MARK: Resume positions

    public func resumePosition(for path: String) -> Double? {
        (try? db.query("SELECT position FROM playback_positions WHERE path = ?", [.text(path)]))?
            .first?["position"]?.double
    }

    public func saveResumePosition(path: String, position: Double, duration: Double?, date: Date = Date()) {
        try? db.execute("""
            INSERT INTO playback_positions (path, position, duration, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET position = excluded.position, duration = excluded.duration,
                updated_at = excluded.updated_at
            """, [.text(path), .real(position), duration.map(SQLValue.real) ?? .null, .real(date.timeIntervalSince1970)])
    }

    public func clearResumePosition(path: String) {
        try? db.execute("DELETE FROM playback_positions WHERE path = ?", [.text(path)])
    }

    // MARK: Backup

    public func snapshot() -> LibrarySnapshot {
        let files = bookmarkedFiles().map { file in
            LibrarySnapshot.File(
                path: file.path,
                updatedAt: file.updatedAt,
                bookmarks: file.bookmarks.map {
                    LibrarySnapshot.Bookmark(positionMs: $0.positionMs, title: $0.title, createdAt: $0.createdAt,
                                             thumbnail: $0.thumbnail)
                }
            )
        }
        let rows = (try? db.query("SELECT path, position, duration, updated_at FROM playback_positions ORDER BY path")) ?? []
        let positions = rows.compactMap { row -> LibrarySnapshot.Position? in
            guard let path = row["path"]?.string, let position = row["position"]?.double else { return nil }
            return LibrarySnapshot.Position(path: path, position: position, duration: row["duration"]?.double,
                                            updatedAt: Date(timeIntervalSince1970: row["updated_at"]?.double ?? 0))
        }
        return LibrarySnapshot(files: files, positions: positions)
    }

    /// Replaces everything with the snapshot's content.
    public func restore(_ snapshot: LibrarySnapshot) throws {
        try db.transaction {
            try db.execute("DELETE FROM bookmarks")
            try db.execute("DELETE FROM media_files")
            try db.execute("DELETE FROM playback_positions")
            for file in snapshot.files where !file.bookmarks.isEmpty {
                let fileID = try touchFile(file.path, date: file.updatedAt)
                for bookmark in file.bookmarks {
                    try db.execute(
                        "INSERT INTO bookmarks (file_id, position_ms, title, thumbnail, created_at) VALUES (?, ?, ?, ?, ?)",
                        [.integer(fileID), .integer(bookmark.positionMs), .text(bookmark.title),
                         bookmark.thumbnail.map(SQLValue.blob) ?? .null, .real(bookmark.createdAt.timeIntervalSince1970)]
                    )
                }
            }
            for position in snapshot.positions {
                saveResumePosition(path: position.path, position: position.position, duration: position.duration,
                                   date: position.updatedAt)
            }
        }
    }
}
