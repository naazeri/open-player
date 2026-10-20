import Foundation

/// Library content in a storage-independent form, used by backups.
public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public struct Bookmark: Codable, Equatable, Sendable {
        public var positionMs: Int64
        public var title: String
        public var createdAt: Date
        public var thumbnail: Data?

        public init(positionMs: Int64, title: String, createdAt: Date, thumbnail: Data?) {
            self.positionMs = positionMs
            self.title = title
            self.createdAt = createdAt
            self.thumbnail = thumbnail
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            positionMs = try c.decode(Int64.self, forKey: .positionMs)
            title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Bookmark"
            createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
            thumbnail = try? c.decodeIfPresent(Data.self, forKey: .thumbnail)
        }
    }

    public struct File: Codable, Equatable, Sendable {
        public var path: String
        public var updatedAt: Date
        public var bookmarks: [Bookmark]

        public init(path: String, updatedAt: Date, bookmarks: [Bookmark]) {
            self.path = path
            self.updatedAt = updatedAt
            self.bookmarks = bookmarks
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? Date(timeIntervalSince1970: 0)
            bookmarks = (try? c.decodeIfPresent(LossyArray<Bookmark>.self, forKey: .bookmarks))?.items ?? []
        }
    }

    public struct Position: Codable, Equatable, Sendable {
        public var path: String
        public var position: Double
        public var duration: Double?
        public var updatedAt: Date

        public init(path: String, position: Double, duration: Double?, updatedAt: Date) {
            self.path = path
            self.position = position
            self.duration = duration
            self.updatedAt = updatedAt
        }
    }

    public var files: [File]
    public var positions: [Position]

    public init(files: [File] = [], positions: [Position] = []) {
        self.files = files
        self.positions = positions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = (try? c.decodeIfPresent(LossyArray<File>.self, forKey: .files))?.items ?? []
        positions = (try? c.decodeIfPresent(LossyArray<Position>.self, forKey: .positions))?.items ?? []
    }
}

public enum BackupError: LocalizedError, Equatable {
    case notABackup
    case newerVersion(Int)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notABackup:
            return "This file is not a Open Player backup."
        case .newerVersion(let version):
            return "This backup was made by a newer version of Open Player (format \(version)). Please update the app to import it."
        case .unreadable(let reason):
            return "The backup file could not be read: \(reason)"
        }
    }
}

/// The export file: one pretty-printed JSON document with settings and the whole library.
public enum BackupCodec {
    public static let formatID = "open-player-backup"
    public static let currentVersion = 1

    struct Envelope: Codable {
        var format: String
        var formatVersion: Int
        var appVersion: String
        var createdAt: Date
        var settings: AppSettings
        var library: LibrarySnapshot
    }

    private struct Header: Decodable {
        var format: String?
        var formatVersion: Int?
    }

    public static func encode(settings: AppSettings, library: LibrarySnapshot, appVersion: String,
                              date: Date = Date()) throws -> Data {
        let envelope = Envelope(format: formatID, formatVersion: currentVersion, appVersion: appVersion,
                                createdAt: date, settings: settings, library: library)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data) throws -> (settings: AppSettings, library: LibrarySnapshot) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw BackupError.notABackup
        }
        guard header.format == formatID else { throw BackupError.notABackup }
        let version = header.formatVersion ?? 1
        if version > currentVersion { throw BackupError.newerVersion(version) }

        // Migrations from older formats go here (none yet: version 1 is the first).
        do {
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let settings = try object["settings"].map {
                try decoder.decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: $0))
            } ?? AppSettings()
            let library = try object["library"].map {
                try decoder.decode(LibrarySnapshot.self, from: JSONSerialization.data(withJSONObject: $0))
            } ?? LibrarySnapshot()
            return (settings, library)
        } catch {
            throw BackupError.unreadable(error.localizedDescription)
        }
    }
}

/// Decodes an array, skipping elements that fail instead of failing the whole array.
struct LossyArray<Element: Decodable>: Decodable {
    var items: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) {
                result.append(item)
            } else {
                _ = try? container.decode(Discard.self)
            }
        }
        items = result
    }

    private struct Discard: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
