#!/bin/zsh
# Builds Open Player.
#   scripts/build.sh            Debug build, linked against Homebrew's libmpv
#   scripts/build.sh release    Release build with libmpv and its libraries copied into the app,
#                               so it keeps working when Homebrew updates or removes mpv, packed
#                               as a .zip and a .dmg
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in xcodegen mpv; do
  command -v $tool >/dev/null || { echo "Missing $tool: brew install $tool"; exit 1; }
done

config=Debug
[[ "${1:-}" == "release" ]] && config=Release

xcodegen generate --quiet
actions=(build)
[[ $config == Release ]] && actions=(clean build)
xcodebuild -project OpenPlayer.xcodeproj -scheme OpenPlayer -configuration $config \
  -derivedDataPath build/DerivedData "${actions[@]}" | grep -E "error:|warning: .*swift|BUILD" || true

app="build/DerivedData/Build/Products/$config/Open Player.app"
[[ -d "$app" ]] || { echo "Build failed"; exit 1; }

if [[ $config == Release ]]; then
  command -v dylibbundler >/dev/null || { echo "Missing dylibbundler: brew install dylibbundler"; exit 1; }
  # Bundle into a copy so the Xcode build output stays untouched.
  rm -rf "build/Open Player.app"
  cp -R "$app" "build/Open Player.app"
  app="build/Open Player.app"
  # dylibbundler empties Frameworks first; keep Sparkle (already embedded by Xcode) out of its way.
  sparkle=$(mktemp -d)
  mv "$app/Contents/Frameworks/Sparkle.framework" "$sparkle/"
  dylibbundler -od -b -x "$app/Contents/MacOS/Open Player" -d "$app/Contents/Frameworks" \
    -p @executable_path/../Frameworks/ </dev/null >/dev/null
  mv "$sparkle/Sparkle.framework" "$app/Contents/Frameworks/"
  rmdir "$sparkle"
  # dylibbundler can add the same rpath twice, which dyld refuses to load.
  for bin in "$app/Contents/MacOS/Open Player" "$app/Contents/Frameworks/"*.dylib; do
    for rpath in "@executable_path/../Frameworks/" "@executable_path/../Frameworks"; do
      while (( $(otool -l "$bin" | grep -c "path $rpath (") > 1 )); do
        install_name_tool -delete_rpath "$rpath" "$bin" 2>/dev/null
      done
    done
  done
  # Bundled Homebrew libraries only run on the macOS they were built for; say so in Info.plist
  # so older systems show a clear "requires macOS …" message instead of crashing.
  minos=$(for f in "$app/Contents/MacOS/Open Player" "$app/Contents/Frameworks/"*.dylib; do
    otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; f=0}'
  done | sort -V | tail -1)
  /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $minos" "$app/Contents/Info.plist"
  codesign --force --deep --sign - "$app"

  version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
  zip="build/Open-Player-$version-macOS-arm64.zip"
  rm -f "$zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

  # Disk image: the app plus an Applications shortcut to drag it onto.
  dmg="build/Open-Player-$version-macOS-arm64.dmg"
  stage=$(mktemp -d)
  ditto "$app" "$stage/Open Player.app"
  ln -s /Applications "$stage/Applications"
  rm -f "$dmg"
  hdiutil create -quiet -volname "Open Player" -srcfolder "$stage" -fs APFS -format ULFO "$dmg"
  rm -rf "${stage:?}"
  codesign --force --sign - "$dmg"
  echo "Built $app ($(du -sh "$app" | cut -f1), needs macOS $minos+), $zip ($(du -h "$zip" | cut -f1)) and $dmg ($(du -h "$dmg" | cut -f1))."
else
  echo "Built $app"
fi
