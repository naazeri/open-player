import AppKit
import OpenPlayerCore
import SwiftUI

/// "Manage Bookmarks…": every bookmark grouped by file, with rename, delete and jump.
final class BookmarkManagerWindowController: NSWindowController {
    init(service: BookmarkService, onJump: @escaping (Bookmark) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Bookmarks"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BookmarkManager")
        let model = BookmarkManagerModel(service: service)
        window.contentView = NSHostingView(rootView: BookmarkManagerView(model: model, onJump: onJump))
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

final class BookmarkManagerModel: ObservableObject {
    @Published var files: [BookmarkedFile] = []
    @Published var filter = ""
    let service: BookmarkService
    private var observer: NSObjectProtocol?

    init(service: BookmarkService) {
        self.service = service
        reload()
        observer = NotificationCenter.default.addObserver(forName: .bookmarksDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() { files = service.bookmarkedFiles() }

    var filteredFiles: [BookmarkedFile] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return files }
        return files.compactMap { file in
            if file.fileName.localizedCaseInsensitiveContains(query) { return file }
            var copy = file
            copy.bookmarks = file.bookmarks.filter { $0.title.localizedCaseInsensitiveContains(query) }
            return copy.bookmarks.isEmpty ? nil : copy
        }
    }
}

private struct BookmarkManagerView: View {
    @ObservedObject var model: BookmarkManagerModel
    let onJump: (Bookmark) -> Void
    @State private var renaming: Bookmark?
    @State private var newTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search files and bookmarks", text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            if model.filteredFiles.isEmpty {
                Text(model.files.isEmpty ? "No bookmarks yet.\nPress P while playing to add one." : "Nothing matches.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.filteredFiles, id: \.path) { file in
                        Section {
                            ForEach(file.bookmarks) { bookmark in
                                row(bookmark)
                            }
                        } header: {
                            HStack {
                                Text(file.fileName).font(.headline)
                                Spacer()
                                Text(file.updatedAt, style: .date).foregroundStyle(.secondary)
                            }
                            .help(file.path)
                        }
                    }
                }
            }
        }
        .sheet(item: $renaming) { bookmark in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename Bookmark").font(.headline)
                TextField("Title", text: $newTitle).frame(width: 300)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Rename") {
                        model.service.rename(bookmark, to: newTitle)
                        renaming = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }

    private func row(_ bookmark: Bookmark) -> some View {
        HStack(spacing: 10) {
            thumbnail(bookmark)
            VStack(alignment: .leading) {
                Text(bookmark.title)
                Text(TimeFormat.long(bookmark.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Go") { onJump(bookmark) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onJump(bookmark) }
        .contextMenu {
            Button("Go to \(TimeFormat.long(bookmark.seconds))") { onJump(bookmark) }
            Button("Rename…") {
                newTitle = bookmark.title
                renaming = bookmark
            }
            Button("Delete", role: .destructive) { model.service.delete(bookmark) }
        }
    }

    @ViewBuilder
    private func thumbnail(_ bookmark: Bookmark) -> some View {
        if let data = bookmark.thumbnail, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 64, height: 36)
                .overlay(Image(systemName: "bookmark.fill").foregroundStyle(.secondary))
        }
    }
}
