import Foundation

/// One bookmark as PotPlayer stores it: `N=<milliseconds>*<title>*<hex thumbnail>`.
public struct PBFEntry: Equatable, Sendable {
    public var positionMs: Int64
    public var title: String
    /// JPEG bytes (PotPlayer wraps them in a BITMAPINFOHEADER; that wrapper is handled by the codec).
    public var thumbnailJPEG: Data?

    public init(positionMs: Int64, title: String, thumbnailJPEG: Data? = nil) {
        self.positionMs = positionMs
        self.title = title
        self.thumbnailJPEG = thumbnailJPEG
    }
}

/// A PotPlayer bookmark file (`.pbf`): an INI file with a `[Bookmark]` section.
/// Lines outside that section are kept as-is when the file is rewritten.
public struct PBFDocument: Equatable, Sendable {
    public var entries: [PBFEntry]
    /// Every line that is not part of the `[Bookmark]` section, in order.
    public var otherLines: [String]

    public init(entries: [PBFEntry] = [], otherLines: [String] = []) {
        self.entries = entries
        self.otherLines = otherLines
    }
}

public enum PBFCodec {
    private static let section = "[Bookmark]"

    // MARK: Decoding

    public static func decode(_ data: Data) -> PBFDocument {
        decode(text: decodeText(data))
    }

    public static func decode(text: String) -> PBFDocument {
        var document = PBFDocument()
        var inBookmarkSection = false
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inBookmarkSection = trimmed.caseInsensitiveCompare(section) == .orderedSame
                if !inBookmarkSection { document.otherLines.append(line) }
                continue
            }
            guard inBookmarkSection else {
                document.otherLines.append(line)
                continue
            }
            if let entry = parseEntry(trimmed) { document.entries.append(entry) }
        }
        // Drop the trailing empty line produced by a final newline.
        while document.otherLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            document.otherLines.removeLast()
        }
        return document
    }

    /// Parses `N=ms*title*hex`. The title may itself contain `*`, so the first and last fields are split off.
    static func parseEntry(_ line: String) -> PBFEntry? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        guard Int(line[..<equals].trimmingCharacters(in: .whitespaces)) != nil else { return nil }
        let value = String(line[line.index(after: equals)...])
        guard let firstStar = value.firstIndex(of: "*"),
              let ms = Int64(value[..<firstStar].trimmingCharacters(in: .whitespaces)) else { return nil }
        let rest = value[value.index(after: firstStar)...]
        var title = String(rest)
        var thumbnail: Data?
        if let lastStar = rest.lastIndex(of: "*") {
            title = String(rest[..<lastStar])
            thumbnail = thumbnailJPEG(fromHex: String(rest[rest.index(after: lastStar)...]))
        }
        return PBFEntry(positionMs: ms, title: title, thumbnailJPEG: thumbnail)
    }

    private static func decodeText(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
        }
        if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? ""
        }
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8) ?? ""
        }
        // No BOM: UTF-16LE without BOM has zero high bytes for ASCII text.
        if data.count >= 4 && data[data.startIndex + 1] == 0 && data[data.startIndex + 3] == 0 {
            return String(data: data, encoding: .utf16LittleEndian) ?? ""
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
    }

    // MARK: Encoding

    /// UTF-16LE with BOM and CRLF line endings, like PotPlayer writes it.
    public static func encode(_ document: PBFDocument) -> Data {
        var lines = [section]
        for (index, entry) in document.entries.enumerated() {
            let hex = entry.thumbnailJPEG.map(thumbnailHex(fromJPEG:)) ?? ""
            lines.append("\(index)=\(entry.positionMs)*\(entry.title)*\(hex)")
        }
        lines.append("\(document.entries.count)=")
        if !document.otherLines.isEmpty {
            lines.append("")
            lines.append(contentsOf: document.otherLines)
        }
        let text = lines.joined(separator: "\r\n") + "\r\n"
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian) ?? Data())
        return data
    }

    // MARK: Thumbnails

    /// PotPlayer thumbnail: 40-byte BITMAPINFOHEADER with biCompression = BI_JPEG (4), then JPEG bytes.
    static func thumbnailJPEG(fromHex hex: String) -> Data? {
        guard let bytes = Data(hexString: hex), bytes.count > 4 else { return nil }
        let raw = [UInt8](bytes.prefix(40))
        if raw.count == 40, readUInt32(raw, 0) == 40, readUInt32(raw, 16) == 4 {
            let jpeg = bytes.dropFirst(40)
            return isJPEG(jpeg) ? Data(jpeg) : nil
        }
        return isJPEG(bytes) ? bytes : nil
    }

    static func thumbnailHex(fromJPEG jpeg: Data) -> String {
        let size = JPEGInfo.dimensions(of: jpeg) ?? (0, 0)
        var header = Data()
        header.appendUInt32(40)                    // biSize
        header.appendUInt32(UInt32(size.width))    // biWidth
        header.appendUInt32(UInt32(size.height))   // biHeight
        header.appendUInt16(1)                     // biPlanes
        header.appendUInt16(32)                    // biBitCount
        header.appendUInt32(4)                     // biCompression = BI_JPEG
        header.appendUInt32(UInt32(jpeg.count))    // biSizeImage
        header.append(Data(count: 16))             // resolution + colour counts
        return (header + jpeg).hexString
    }

    private static func isJPEG<D: DataProtocol>(_ data: D) -> Bool {
        let prefix = Array(data.prefix(2))
        return prefix == [0xFF, 0xD8]
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

/// Finds the `.pbf` that belongs to a media file. PotPlayer has used both `name.pbf` and `name.ext.pbf`.
public enum PBFLocator {
    public static func candidates(for media: URL) -> [URL] {
        let folder = media.deletingLastPathComponent()
        let base = media.deletingPathExtension().lastPathComponent
        return [
            folder.appendingPathComponent(base + ".pbf"),
            folder.appendingPathComponent(media.lastPathComponent + ".pbf"),
        ]
    }

    public static func existing(for media: URL, fileManager: FileManager = .default) -> URL? {
        candidates(for: media).first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Where a new `.pbf` goes when creating them is enabled.
    public static func preferred(for media: URL) -> URL {
        candidates(for: media)[0]
    }
}

/// The sync rule between the central database and a `.pbf` file.
public enum BookmarkSync {
    /// Given what the database holds and what the `.pbf` holds, returns the entries the database must be
    /// replaced with, or nil when they already agree. The `.pbf` wins every conflict; thumbnails the
    /// `.pbf` lacks are kept from the database when the position matches.
    public static func resolve(database: [PBFEntry], pbf: [PBFEntry]) -> [PBFEntry]? {
        struct Key: Hashable { let ms: Int64; let title: String }
        let dbKeys = database.map { Key(ms: $0.positionMs, title: $0.title) }.sorted { ($0.ms, $0.title) < ($1.ms, $1.title) }
        let pbfKeys = pbf.map { Key(ms: $0.positionMs, title: $0.title) }.sorted { ($0.ms, $0.title) < ($1.ms, $1.title) }
        if dbKeys == pbfKeys { return nil }

        var thumbnails: [Int64: Data] = [:]
        for entry in database { if let thumb = entry.thumbnailJPEG { thumbnails[entry.positionMs] = thumb } }
        return pbf.map { entry in
            var merged = entry
            if merged.thumbnailJPEG == nil { merged.thumbnailJPEG = thumbnails[entry.positionMs] }
            return merged
        }
    }
}

// MARK: - Helpers

enum JPEGInfo {
    /// Reads width/height from the first SOF marker.
    static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        while index + 9 < bytes.count {
            guard bytes[index] == 0xFF else { index += 1; continue }
            let marker = bytes[index + 1]
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { index += 2; continue }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
                return (width, height)
            }
            index += 2 + length
        }
        return nil
    }
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = Self.nibble(chars[index]), let low = Self.nibble(chars[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        self = data
    }

    var hexString: String {
        let digits = Array("0123456789ABCDEF".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)])
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
