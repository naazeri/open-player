# Open Player — Build Plan

A personal, PotPlayer-like media player for Apple Silicon Macs (macOS 14+).
Goal: keep PotPlayer muscle memory (keys, bookmarks, folder playlist) with a native, efficient Mac app.

## Stack

| Layer | Choice |
|---|---|
| Playback engine | libmpv 0.41 (Homebrew), hardware decoding via VideoToolbox (`hwdec=auto-safe`) |
| Video output | libmpv render API (OpenGL) on a `CAOpenGLLayer` |
| UI | AppKit window/controls, SwiftUI for Settings, Playlist and Bookmark manager |
| Storage | SQLite (system `libsqlite3`) for bookmarks and resume positions; JSON for settings |
| Project | XcodeGen (`project.yml`) + local Swift package `OpenPlayerCore` for all testable logic |
| Arch | arm64 only, no sandbox, ad-hoc signed, MIT license |

## Layout

```
project.yml                  XcodeGen spec (app target)
Packages/OpenPlayerCore/           Pure Swift logic + unit tests (swift test)
  KeyBindings                Action list, PotPlayer default keymap, key combo parsing
  Playlist                   Media extensions, folder scan, natural sort
  Bookmarks                  SQLite library store, PotPlayer .pbf codec + sync rule
  Settings                   Versioned, lenient Codable settings
  Backup                     Export/import file (versioned JSON)
OpenPlayer/                  macOS app (AppKit + SwiftUI)
  MPV                        libmpv wrapper, video layer
  Player                     Window controller, control bar, seek bar, key handling
  Bookmarks                  H menu, bookmark manager window
  Settings                   Settings window (tabs incl. shortcut recorder, backup)
```

## Phases

1. **Scaffold** — XcodeGen project, OpenPlayerCore package, bridging header for libmpv, MIT license, README.
2. **Core logic + tests** — key combos/default map, folder scanner, SQLite store, `.pbf` codec, settings, backup codec.
3. **Playback** — mpv wrapper, OpenGL video layer, window sizing (video resolution; compact window for audio), fullscreen, drag & drop, open from Finder.
4. **Controls** — control bar with seek bar (bookmark ticks), volume, speed; auto-hide; mpv OSD for feedback.
5. **Keyboard** — PotPlayer default keys by physical key code (works with Persian layout), hold-to-repeat with own timer (configurable delay/interval), rebinding.
6. **Playlist** — auto-add every video/audio file of the opened file's folder (natural sort), auto-advance, PageUp/PageDown, playlist panel (F6).
7. **Bookmarks** — `P` adds (`Bookmark N` + time + thumbnail); `H` menu: files sorted by last bookmark change, current file bold, submenu sorted by time, right-click rename/delete, bookmark manager window.
8. **Settings + Backup** — all steps and keys configurable; export/import of settings + library to one JSON file; old/newer/corrupt files never crash.
9. **Persian** — subtitle encoding auto-detect with Windows-1256 option, configurable subtitle font.
10. **Verify** — unit tests, build, launch with generated test media, check rendering, resizing and audio mode.

## Key rules

- Bookmarks always live in the central DB. If a PotPlayer `.pbf` exists next to the media file
  (`name.pbf` or `name.ext.pbf`), it is read when the file opens and **wins on conflict**, and is
  rewritten whenever bookmarks change. New `.pbf` files are only created if enabled in Settings.
- `.pbf` format: `[Bookmark]` section, lines `N=<ms>*<title>*<hex thumbnail>`, UTF-16LE with BOM;
  the thumbnail is a `BITMAPINFOHEADER` (BI_JPEG) followed by JPEG bytes.
- Backup file carries `format` + `formatVersion`. Older versions are migrated, newer or foreign
  files show an error. Missing fields fall back to defaults.

## Default keys (from PotPlayer 1.7.22619 `English.ini`)

| Action | Key |
|---|---|
| Play/Pause | Space |
| Seek ±5 s / ±30 s / ±60 s / ±300 s | Left/Right · Ctrl(+⌘)+Left/Right · Shift+Left/Right · Ctrl+Alt+Left/Right |
| Prev/Next frame | D / F |
| Speed −/+/reset | X / C / Z |
| Volume ±5 % / Mute | Up/Down / M |
| Prev/Next file | PageUp / PageDown |
| Add bookmark / Bookmark menu | P / H |
| Fullscreen | Enter, Alt+Enter |
| Jump to time / to start | G / Backspace |
| Subtitles show-hide / cycle / load | Alt+H / Alt+L / Alt+O |
| Subtitle sync −/+/reset | , / . / `/` |
| Audio cycle / audio sync | Alt+A / Shift+, Shift+. |
| Window size 0.5×–2× | 1 2 3 4 |
| Stay on top | Ctrl+T |
| Info OSD | Tab |
| Open / Open folder / Close | Ctrl+O, F3 / F2 / F4 |
| Preferences / Playlist | F5 / F6 |
| Save frame | Ctrl+E |

macOS reserves Ctrl+Left/Right (switch Spaces) and Ctrl+Up/Down (Mission Control); disable them in
System Settings → Keyboard → Keyboard Shortcuts → Mission Control, or use the ⌘ alternatives.
