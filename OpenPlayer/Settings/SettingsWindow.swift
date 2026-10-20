import AppKit
import OpenPlayerCore
import SwiftUI

enum SettingsTab: String, Hashable {
    case general, playback, subtitles, shortcuts, backup
}

final class SettingsWindowController: NSWindowController {
    private let selection: SettingsSelection

    init(store: SettingsStore, backup: BackupController) {
        selection = SettingsSelection()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 460)
        window.contentView = NSHostingView(rootView: SettingsView(store: store, backup: backup, selection: selection))
        window.setFrameAutosaveName("SettingsWindow")
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

private struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let backup: BackupController
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralTab(store: store).tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            PlaybackTab(store: store).tabItem { Label("Playback", systemImage: "play.circle") }.tag(SettingsTab.playback)
            SubtitlesTab(store: store).tabItem { Label("Subtitles", systemImage: "captions.bubble") }.tag(SettingsTab.subtitles)
            ShortcutsTab(store: store).tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(SettingsTab.shortcuts)
            BackupTab(backup: backup).tabItem { Label("Backup", systemImage: "externaldrive") }.tag(SettingsTab.backup)
        }
        .padding(12)
        .frame(minWidth: 540, minHeight: 440)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Opening files") {
                Picker("Add to the playlist from the same folder", selection: $store.value.playlistScope) {
                    ForEach(PlaylistScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Resume playback where I left off", isOn: $store.value.resumePlayback)
                Toggle("Resize the window to the video's resolution", isOn: $store.value.resizeWindowToVideo)
            }
            Section("Mouse") {
                Toggle("Mouse wheel changes the volume", isOn: $store.value.mouseWheelVolume)
            }
            Section("Decoding") {
                Toggle("Use hardware decoding (VideoToolbox)", isOn: $store.value.hardwareDecoding)
            }
            Section("Updates") {
                Toggle("Check for new versions on GitHub once a day", isOn: $store.value.checkForUpdates)
            }
            Section {
                Toggle("Create PotPlayer .pbf files for new bookmarks", isOn: $store.value.createPBFFiles)
            } header: {
                Text("Bookmarks")
            } footer: {
                Text("Bookmarks are always stored in Open Player's database. When a PotPlayer .pbf file already sits next to a video, it is kept up to date too, and its content wins if the two disagree.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Playback

private struct PlaybackTab: View {
    @ObservedObject var store: SettingsStore

    private var keyMap: KeyMap { store.value.keyMap }

    var body: some View {
        Form {
            Section("Seek steps") {
                ForEach(0..<4, id: \.self) { index in
                    LabeledContent(seekLabel(index)) {
                        HStack {
                            TextField("", value: seekBinding(index), format: .number.precision(.fractionLength(0...1)))
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                            Text("seconds").foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("Precise seeking (exact frame instead of nearest keyframe)", isOn: $store.value.preciseSeeking)
            }
            Section("Steps") {
                Stepper(value: $store.value.volumeStep, in: 1...25, step: 1) {
                    LabeledContent("Volume step (Up/Down)", value: "\(Int(store.value.volumeStep))%")
                }
                Stepper(value: $store.value.speedStep, in: 0.05...0.5, step: 0.05) {
                    LabeledContent("Speed step (C/X)", value: String(format: "%.2f×", store.value.speedStep))
                }
            }
            Section {
                LabeledContent("Delay before repeating") {
                    Slider(value: $store.value.keyRepeatDelay, in: 0.1...1.0, step: 0.05)
                    Text(String(format: "%.2f s", store.value.keyRepeatDelay)).monospacedDigit().frame(width: 52)
                }
                LabeledContent("Repeat interval") {
                    Slider(value: $store.value.keyRepeatInterval, in: 0.02...0.3, step: 0.01)
                    Text(String(format: "%.2f s", store.value.keyRepeatInterval)).monospacedDigit().frame(width: 52)
                }
            } header: {
                Text("Holding a key")
            } footer: {
                Text("Seek, volume, speed and frame-step keys repeat while held down.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func seekLabel(_ index: Int) -> String {
        let actions: [PlayerAction] = [.seekForward1, .seekForward2, .seekForward3, .seekForward4]
        let combos = keyMap.combos(for: actions[index]).map(\.description)
        return combos.isEmpty ? "Step \(index + 1) (no key)" : combos.joined(separator: ", ")
    }

    private func seekBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { store.value.seekStep(index) },
            set: { newValue in
                store.update { settings in
                    settings.seekSteps[index] = min(3600, max(0.1, newValue))
                }
            }
        )
    }
}

// MARK: - Subtitles

private struct SubtitlesTab: View {
    @ObservedObject var store: SettingsStore
    private let families = NSFontManager.shared.availableFontFamilies

    private let encodings: [(String, String)] = [
        ("auto", "Auto-detect"),
        ("UTF-8", "UTF-8"),
        ("CP1256", "Windows-1256 (Persian / Arabic)"),
        ("ISO-8859-6", "ISO-8859-6 (Arabic)"),
        ("CP1252", "Windows-1252 (Western)"),
        ("UTF-16", "UTF-16"),
    ]

    var body: some View {
        Form {
            Section("Loading") {
                Toggle("Load subtitles with the same name automatically", isOn: $store.value.autoLoadSubtitles)
                Picker("Text encoding", selection: $store.value.subtitleEncoding) {
                    ForEach(encodings, id: \.0) { Text($0.1).tag($0.0) }
                }
                Text("Old Persian .srt files are often Windows-1256. Choose it if auto-detect shows garbled text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Font", selection: $store.value.subtitleFont) {
                    Text("Default").tag("")
                    Divider()
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Size") {
                    Slider(value: $store.value.subtitleScale, in: 0.5...3, step: 0.05)
                    Text(String(format: "%.0f%%", store.value.subtitleScale * 100)).monospacedDigit().frame(width: 52)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutsTab: View {
    @ObservedObject var store: SettingsStore
    @State private var recording: PlayerAction?
    @State private var message = ""

    private var keyMap: KeyMap { store.value.keyMap }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(PlayerAction.Category.allCases, id: \.self) { category in
                    Section(category.rawValue) {
                        ForEach(PlayerAction.allCases.filter { $0.category == category }) { action in
                            row(action)
                        }
                    }
                }
            }
            HStack {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Reset All to PotPlayer Defaults") {
                    store.update { $0.keyOverrides = [:] }
                    message = "All shortcuts were reset."
                }
            }
            Text("macOS uses Ctrl+Arrow keys for Mission Control. To use them here, turn them off in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $recording) { action in
            KeyRecorderSheet(action: action, seekSteps: store.value.seekSteps) { combo in
                if let combo { add(combo, to: action) }
                recording = nil
            }
        }
    }

    private func row(_ action: PlayerAction) -> some View {
        HStack {
            Text(action.title(seekSteps: store.value.seekSteps))
            Spacer()
            ForEach(keyMap.combos(for: action), id: \.self) { combo in
                HStack(spacing: 3) {
                    Text(combo.description).font(.system(.caption, design: .monospaced))
                    Button {
                        remove(combo, from: action)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove \(combo.description)")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            }
            Button {
                recording = action
            } label: {
                Image(systemName: "plus")
            }
            .help("Add a shortcut")
        }
    }

    private func add(_ combo: KeyCombo, to action: PlayerAction) {
        var map = keyMap
        if let other = map.conflict(for: combo, excluding: action) {
            map.set(map.combos(for: other).filter { $0 != combo }, for: other)
            message = "\(combo) was moved from “\(other.title(seekSteps: store.value.seekSteps))”."
        } else {
            message = ""
        }
        if !map.combos(for: action).contains(combo) {
            map.set(map.combos(for: action) + [combo], for: action)
        }
        store.update { $0.keyOverrides = map.overrides }
    }

    private func remove(_ combo: KeyCombo, from action: PlayerAction) {
        var map = keyMap
        map.set(map.combos(for: action).filter { $0 != combo }, for: action)
        store.update { $0.keyOverrides = map.overrides }
    }
}

/// Captures the next key press (with modifiers) as a shortcut.
private struct KeyRecorderSheet: View {
    let action: PlayerAction
    let seekSteps: [Double]
    let onFinish: (KeyCombo?) -> Void
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 14) {
            Text("New shortcut for “\(action.title(seekSteps: seekSteps))”").font(.headline)
            Text("Press the key combination now…").foregroundStyle(.secondary)
            Button("Cancel") { finish(nil) }
        }
        .padding(24)
        .frame(minWidth: 320)
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                finish(KeyCombo(event.keyCode, KeyInputHandler.modifiers(of: event.modifierFlags)))
                return nil
            }
        }
        .onDisappear { removeMonitor() }
    }

    private func finish(_ combo: KeyCombo?) {
        removeMonitor()
        onFinish(combo)
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Backup

private struct BackupTab: View {
    let backup: BackupController

    var body: some View {
        Form {
            Section {
                LabeledContent("Export") {
                    Button("Export Backup…") { backup.export() }
                }
                LabeledContent("Import") {
                    Button("Import Backup…") { backup.importBackup() }
                }
            } header: {
                Text("Settings and bookmarks")
            } footer: {
                Text("A backup is one JSON file with all settings, shortcuts, bookmarks (with thumbnails) and resume positions. Importing replaces what you have now. Backups from older versions are upgraded automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
