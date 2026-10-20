import AppKit
import OpenPlayerCore
import SwiftUI

/// Floating playlist window (F6).
final class PlaylistPanelController: NSWindowController {
    init(model: PlaylistModel, onPlay: @escaping (Int) -> Void) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "Playlist"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("PlaylistPanel")
        panel.contentView = NSHostingView(rootView: PlaylistView(model: model, onPlay: onPlay))
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func toggle(relativeTo playerWindow: NSWindow?) {
        guard let window else { return }
        if window.isVisible {
            window.orderOut(nil)
            return
        }
        if window.frame.origin == .zero, let player = playerWindow {
            window.setFrameTopLeftPoint(NSPoint(x: player.frame.maxX + 8, y: player.frame.maxY))
        }
        window.orderFront(nil)
    }
}

private struct PlaylistView: View {
    @ObservedObject var model: PlaylistModel
    let onPlay: (Int) -> Void
    @State private var selection: Int?

    var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                Text("The playlist is empty.\nOpen a file and its folder is added automatically.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        ForEach(Array(model.items.enumerated()), id: \.offset) { index, url in
                            row(index: index, url: url)
                                .tag(index)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { onPlay(index) }
                        }
                    }
                    .onAppear { if let current = model.currentIndex { proxy.scrollTo(current, anchor: .center) } }
                    .onChange(of: model.currentIndex) { _, current in
                        if let current { withAnimation { proxy.scrollTo(current, anchor: .center) } }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(model.items.count) files")
                Spacer()
                Text("Double-click to play")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func row(index: Int, url: URL) -> some View {
        let isCurrent = index == model.currentIndex
        return HStack(spacing: 8) {
            Image(systemName: isCurrent ? "play.fill" : (MediaTypes.kind(of: url) == .audio ? "music.note" : "film"))
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(url.lastPathComponent)
                .fontWeight(isCurrent ? .bold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(url.path)
    }
}
