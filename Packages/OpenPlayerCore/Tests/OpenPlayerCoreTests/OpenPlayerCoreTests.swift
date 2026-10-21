import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OpenPlayerCore

final class KeyComboTests: XCTestCase {
    func testDescriptionRoundTrip() {
        let combo = KeyCombo(KeyCodes.left, [.control, .option])
        XCTAssertEqual(combo.description, "Ctrl+Alt+Left")
        XCTAssertEqual(KeyCombo(string: "Ctrl+Alt+Left"), combo)
        XCTAssertEqual(KeyCombo(string: "option+control+left"), combo)
        XCTAssertEqual(KeyCombo(string: "Shift+,"), KeyCombo(KeyCodes.comma, .shift))
        XCTAssertEqual(KeyCombo(string: "NumpadPlus")?.keyCode, 0x45)
        XCTAssertNil(KeyCombo(string: "Hyper+P"))
        XCTAssertNil(KeyCombo(string: ""))
    }

    func testEveryKnownKeyNameRoundTrips() {
        for code in UInt16(0)...UInt16(0x7F) {
            let combo = KeyCombo(code, [.shift])
            XCTAssertEqual(KeyCombo(string: combo.description), combo, "key \(code)")
        }
    }

    func testDefaultsFollowPotPlayer() {
        let map = KeyMap()
        XCTAssertEqual(map.action(for: KeyCombo(KeyCodes.space)), .playPause)
        XCTAssertEqual(map.action(for: KeyCombo(KeyCodes.p)), .addBookmark)
        XCTAssertEqual(map.action(for: KeyCombo(KeyCodes.h)), .showBookmarks)
        XCTAssertEqual(map.action(for: KeyCombo(KeyCodes.h, .option)), .toggleSubtitles)
        XCTAssertEqual(map.action(for: KeyCombo(KeyCodes.right, .control)), .seekForward2)
        XCTAssertEqual(map.action(for: KeyCombo(KeyCodes.c)), .speedUp)
        XCTAssertEqual(map.action(for: KeyCombo(KeyCodes.pageDown)), .nextFile)
    }

    func testNoDefaultComboIsSharedByTwoActions() {
        var seen: [KeyCombo: PlayerAction] = [:]
        for (action, combos) in DefaultKeyMap.bindings {
            for combo in combos {
                XCTAssertNil(seen[combo], "\(combo) used by \(seen[combo]!) and \(action)")
                seen[combo] = action
            }
        }
        XCTAssertEqual(Set(DefaultKeyMap.bindings.keys), Set(PlayerAction.allCases))
    }

    func testOverridesRoundTripAndIgnoreJunk() {
        var map = KeyMap()
        map.set([KeyCombo(KeyCodes.b)], for: .addBookmark)
        XCTAssertEqual(map.overrides, ["addBookmark": ["B"]])

        let restored = KeyMap(overrides: map.overrides.merging(["noSuchAction": ["P"], "mute": ["Bogus+Key", "M"]]) { a, _ in a })
        XCTAssertEqual(restored.action(for: KeyCombo(KeyCodes.b)), .addBookmark)
        XCTAssertNil(restored.action(for: KeyCombo(KeyCodes.p)))
        XCTAssertEqual(restored.combos(for: .mute), [KeyCombo(KeyCodes.m)])
    }
}

final class FolderScannerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["ep10.mkv", "ep2.mkv", "ep1.mp4", "song.mp3", "notes.txt", "._ep3.mkv", ".hidden.mkv",
                     "subs.srt", "درس ۲.mp4"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested.mkv"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    func testAllMediaNaturalOrder() {
        let list = FolderScanner.playlist(for: folder.appendingPathComponent("ep2.mkv"), scope: .allMedia)
        XCTAssertEqual(names(list), ["ep1.mp4", "ep2.mkv", "ep10.mkv", "song.mp3", "درس ۲.mp4"])
    }

    func testSameExtension() {
        let list = FolderScanner.playlist(for: folder.appendingPathComponent("ep2.mkv"), scope: .sameExtension)
        XCTAssertEqual(names(list), ["ep2.mkv", "ep10.mkv"])
    }

    func testSameKind() {
        let list = FolderScanner.playlist(for: folder.appendingPathComponent("song.mp3"), scope: .sameKind)
        XCTAssertEqual(names(list), ["song.mp3"])
    }

    func testUnknownExtensionIsStillPlayed() {
        let file = folder.appendingPathComponent("notes.txt")
        XCTAssertTrue(names(FolderScanner.playlist(for: file, scope: .sameExtension)).contains("notes.txt"))
    }
}

final class PBFTests: XCTestCase {
    func testDecodePotPlayerStyleFile() throws {
        let jpeg = try makeJPEG()
        let hex = PBFCodec.thumbnailHex(fromJPEG: jpeg)
        let text = "[Bookmark]\r\n0=200328*Bookmark 1*\(hex)\r\n1=500*Intro * part*\r\n2=\r\n\r\n[Other]\r\nkey=value\r\n"
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)

        let doc = PBFCodec.decode(data)
        XCTAssertEqual(doc.entries.count, 2)
        XCTAssertEqual(doc.entries[0].positionMs, 200_328)
        XCTAssertEqual(doc.entries[0].title, "Bookmark 1")
        XCTAssertEqual(doc.entries[0].thumbnailJPEG, jpeg)
        XCTAssertEqual(doc.entries[1].title, "Intro * part")
        XCTAssertNil(doc.entries[1].thumbnailJPEG)
        XCTAssertEqual(doc.otherLines, ["[Other]", "key=value"])
    }

    func testEncodeRoundTripKeepsOtherSections() throws {
        let doc = PBFDocument(
            entries: [PBFEntry(positionMs: 1000, title: "نشانک فارسی", thumbnailJPEG: try makeJPEG()),
                      PBFEntry(positionMs: 2000, title: "Bookmark 2")],
            otherLines: ["[Other]", "a=b"]
        )
        let data = PBFCodec.encode(doc)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xFE])
        XCTAssertEqual(PBFCodec.decode(data), doc)
    }

    func testThumbnailHeaderMatchesPotPlayer() throws {
        let jpeg = try makeJPEG(width: 72, height: 40)
        let hex = PBFCodec.thumbnailHex(fromJPEG: jpeg)
        // biSize=40, biWidth=72, biHeight=40, planes=1, bpp=32, BI_JPEG
        XCTAssertTrue(hex.hasPrefix("28000000" + "48000000" + "28000000" + "0100" + "2000" + "04000000"))
    }

    func testDecodeWithoutBOMAndGarbage() {
        XCTAssertEqual(PBFCodec.decode(Data("[Bookmark]\n0=42*A*\n".utf8)).entries, [PBFEntry(positionMs: 42, title: "A")])
        XCTAssertTrue(PBFCodec.decode(Data([0x00, 0xFF, 0x13])).entries.isEmpty)
        XCTAssertTrue(PBFCodec.decode(text: "[Bookmark]\nx=abc*A*\n0=notanumber*B*").entries.isEmpty)
    }

    func testSyncPrefersPBF() {
        let thumb = Data([0xFF, 0xD8, 0x01])
        let db = [PBFEntry(positionMs: 1000, title: "Bookmark 1", thumbnailJPEG: thumb)]
        XCTAssertNil(BookmarkSync.resolve(database: db, pbf: [PBFEntry(positionMs: 1000, title: "Bookmark 1")]))

        let pbf = [PBFEntry(positionMs: 1000, title: "Renamed on Windows"), PBFEntry(positionMs: 5000, title: "New")]
        let resolved = BookmarkSync.resolve(database: db, pbf: pbf)
        XCTAssertEqual(resolved?.map(\.title), ["Renamed on Windows", "New"])
        XCTAssertEqual(resolved?.first?.thumbnailJPEG, thumb)
        XCTAssertEqual(BookmarkSync.resolve(database: db, pbf: []), [])
    }

    func testLocator() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let media = folder.appendingPathComponent("movie.mkv")
        XCTAssertNil(PBFLocator.existing(for: media))
        FileManager.default.createFile(atPath: folder.appendingPathComponent("movie.mkv.pbf").path, contents: Data())
        XCTAssertEqual(PBFLocator.existing(for: media)?.lastPathComponent, "movie.mkv.pbf")
        XCTAssertEqual(PBFLocator.preferred(for: media).lastPathComponent, "movie.pbf")
    }
}

final class LibraryStoreTests: XCTestCase {
    func testBookmarksOrderingAndNaming() throws {
        let store = try LibraryStore(path: ":memory:")
        let t0 = Date(timeIntervalSince1970: 1000)
        try store.addBookmark(path: "/a.mp4", positionMs: 9000, date: t0)
        try store.addBookmark(path: "/a.mp4", positionMs: 3000, date: t0.addingTimeInterval(1))
        try store.addBookmark(path: "/b.mp4", positionMs: 1000, date: t0.addingTimeInterval(2))

        var files = store.bookmarkedFiles()
        XCTAssertEqual(files.map(\.fileName), ["b.mp4", "a.mp4"])
        XCTAssertEqual(files[1].bookmarks.map(\.positionMs), [3000, 9000])
        XCTAssertEqual(files[1].bookmarks.map(\.title), ["Bookmark 2", "Bookmark 1"])
        XCTAssertEqual(files[1].bookmarks[0].displayTitle, "Bookmark 2 — 00:00:03")

        // Renaming counts as a change, so a.mp4 moves to the top.
        try store.renameBookmark(id: files[1].bookmarks[1].id, to: "Ending", date: t0.addingTimeInterval(3))
        files = store.bookmarkedFiles()
        XCTAssertEqual(files.map(\.fileName), ["a.mp4", "b.mp4"])

        // A late thumbnail doesn't reorder files.
        try store.setThumbnail(id: files[1].bookmarks[0].id, data: Data([9]))
        XCTAssertEqual(store.bookmarkedFiles().map(\.fileName), ["a.mp4", "b.mp4"])
        XCTAssertEqual(store.bookmarkedFiles()[1].bookmarks[0].thumbnail, Data([9]))

        // Deleting the last bookmark removes the file from the list.
        try store.deleteBookmark(id: files[1].bookmarks[0].id)
        XCTAssertEqual(store.bookmarkedFiles().map(\.fileName), ["a.mp4"])
    }

    func testReplaceAndResume() throws {
        let store = try LibraryStore(path: ":memory:")
        try store.addBookmark(path: "/a.mp4", positionMs: 1)
        try store.replaceBookmarks(path: "/a.mp4", with: [PBFEntry(positionMs: 7, title: "X")])
        XCTAssertEqual(store.bookmarks(for: "/a.mp4").map(\.title), ["X"])
        try store.replaceBookmarks(path: "/a.mp4", with: [])
        XCTAssertTrue(store.bookmarkedFiles().isEmpty)

        XCTAssertNil(store.resumePosition(for: "/a.mp4"))
        store.saveResumePosition(path: "/a.mp4", position: 12.5, duration: 100)
        store.saveResumePosition(path: "/a.mp4", position: 20, duration: 100)
        XCTAssertEqual(store.resumePosition(for: "/a.mp4"), 20)
        store.clearResumePosition(path: "/a.mp4")
        XCTAssertNil(store.resumePosition(for: "/a.mp4"))
    }

    func testSchemaSurvivesReopen() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let store = try LibraryStore(path: path)
            try store.addBookmark(path: "/a.mp4", positionMs: 1, thumbnail: Data([1, 2, 3]))
        }
        let reopened = try LibraryStore(path: path)
        XCTAssertEqual(reopened.bookmarks(for: "/a.mp4").first?.thumbnail, Data([1, 2, 3]))
    }
}

final class SettingsAndBackupTests: XCTestCase {
    func testLenientSettingsDecoding() throws {
        let json = #"{"volumeStep": "loud", "seekSteps": [10], "volume": 500, "futureOption": true, "playlistScope": "nope"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.volumeStep, 5)
        XCTAssertEqual(settings.seekSteps, [10, 30, 60, 300])
        XCTAssertEqual(settings.volume, 100)
        XCTAssertEqual(settings.playlistScope, .allMedia)
    }

    func testKeepRunningAfterCloseDefaultsAndPersists() throws {
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).keepRunningAfterClose)
        let wrongType = #"{"keepRunningAfterClose": "x"}"#
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data(wrongType.utf8)).keepRunningAfterClose)
        var settings = AppSettings()
        settings.keepRunningAfterClose = false
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(roundTrip.keepRunningAfterClose)
    }

    func testNextFileCountdownDefaultsAndPersists() throws {
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).nextFileCountdown)
        var settings = AppSettings()
        settings.nextFileCountdown = false
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).nextFileCountdown)
        XCTAssertEqual(AppSettings().nextFileCountdownSeconds, 4)
        settings.nextFileCountdownSeconds = 7
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).nextFileCountdownSeconds, 7)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"nextFileCountdownSeconds": 99}"#.utf8)).nextFileCountdownSeconds, 30)
    }

    func testSpeedSteps() {
        // Label click: 1.0 → 1.25 → 1.5 → 1.75 → 2.0 → 1.0
        var speed = 1.0
        var cycle: [Double] = []
        for _ in 0..<5 { speed = SpeedSteps.cycle(from: speed); cycle.append(speed) }
        XCTAssertEqual(cycle, [1.25, 1.5, 1.75, 2.0, 1.0])
        XCTAssertEqual(SpeedSteps.cycle(from: 1.1), 1.25)
        XCTAssertEqual(SpeedSteps.cycle(from: 0.8), 1.0)
        XCTAssertEqual(SpeedSteps.cycle(from: 2.3), 1.0)

        // C/X snap to the 0.1 grid.
        XCTAssertEqual(SpeedSteps.up(from: 1.75, step: 0.1), 1.8)
        XCTAssertEqual(SpeedSteps.up(from: 1.8, step: 0.1), 1.9)
        XCTAssertEqual(SpeedSteps.down(from: 1.75, step: 0.1), 1.7)
        XCTAssertEqual(SpeedSteps.down(from: 1.8, step: 0.1), 1.7)
        XCTAssertEqual(SpeedSteps.up(from: 1.0, step: 0.1), 1.1)
        XCTAssertEqual(SpeedSteps.down(from: 0.1, step: 0.1), 0.1)
        XCTAssertEqual(SpeedSteps.up(from: 4.0, step: 0.1), 4.0)

        XCTAssertEqual(SpeedSteps.label(1), "1.0×")
        XCTAssertEqual(SpeedSteps.label(1.25), "1.25×")
        XCTAssertEqual(SpeedSteps.label(1.1), "1.1×")
        XCTAssertEqual(SpeedSteps.label(2), "2.0×")
    }

    func testBackupRoundTrip() throws {
        let store = try LibraryStore(path: ":memory:")
        try store.addBookmark(path: "/a.mp4", positionMs: 1000, thumbnail: Data([0xFF, 0xD8]))
        store.saveResumePosition(path: "/b.mp4", position: 33, duration: nil)
        var settings = AppSettings()
        settings.volumeStep = 10
        settings.keyOverrides = ["addBookmark": ["B"]]

        let data = try BackupCodec.encode(settings: settings, library: store.snapshot(), appVersion: "1.0")
        let decoded = try BackupCodec.decode(data)
        XCTAssertEqual(decoded.settings, settings)

        let other = try LibraryStore(path: ":memory:")
        try other.addBookmark(path: "/old.mp4", positionMs: 5)
        try other.restore(decoded.library)
        XCTAssertEqual(other.bookmarkedFiles().map(\.path), ["/a.mp4"])
        XCTAssertEqual(other.bookmarks(for: "/a.mp4").first?.thumbnail, Data([0xFF, 0xD8]))
        XCTAssertEqual(other.resumePosition(for: "/b.mp4"), 33)
    }

    func testBackupErrors() {
        XCTAssertThrowsError(try BackupCodec.decode(Data("not json".utf8))) {
            XCTAssertEqual($0 as? BackupError, .notABackup)
        }
        XCTAssertThrowsError(try BackupCodec.decode(Data(#"{"format":"something-else"}"#.utf8))) {
            XCTAssertEqual($0 as? BackupError, .notABackup)
        }
        XCTAssertThrowsError(try BackupCodec.decode(Data(#"{"format":"open-player-backup","formatVersion":99}"#.utf8))) {
            XCTAssertEqual($0 as? BackupError, .newerVersion(99))
        }
    }

    func testOldOrPartialBackupStillImports() throws {
        let json = """
        {"format":"open-player-backup","formatVersion":1,
         "settings":{"volumeStep":2},
         "library":{"files":[{"path":"/a.mp4","bookmarks":[{"positionMs":5},{"broken":true}]},{"nopath":1}]}}
        """
        let decoded = try BackupCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded.settings.volumeStep, 2)
        XCTAssertEqual(decoded.library.files.count, 1)
        XCTAssertEqual(decoded.library.files[0].bookmarks.map(\.positionMs), [5])
        XCTAssertTrue(decoded.library.positions.isEmpty)
    }

    func testVersionComparison() {
        XCTAssertLessThan(AppVersion("1.0.0")!, AppVersion("v1.0.1")!)
        XCTAssertLessThan(AppVersion("1.9")!, AppVersion("1.10")!)
        XCTAssertEqual(AppVersion("1.0")!, AppVersion("v1.0.0")!)
        XCTAssertEqual(AppVersion("2.0.0-beta")!.description, "2.0.0")
        XCTAssertFalse(AppVersion("1.2.0")! < AppVersion("1.1.9")!)
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion(""))
    }

    func testTimeFormat() {
        XCTAssertEqual(TimeFormat.long(200.328), "00:03:20")
        XCTAssertEqual(TimeFormat.short(65), "01:05")
        XCTAssertEqual(TimeFormat.short(65, reference: 4000), "0:01:05")
        XCTAssertEqual(TimeFormat.parse("1:02:03.5"), 3723.5)
        XCTAssertEqual(TimeFormat.parse("90"), 90)
        XCTAssertNil(TimeFormat.parse("a:b"))
        XCTAssertEqual(TimeFormat.stepLabel(90), "1 Min. 30 Sec.")
    }
}

// MARK: - Helpers

func makeJPEG(width: Int = 16, height: Int = 9) throws -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}
