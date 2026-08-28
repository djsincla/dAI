#!/bin/bash
#
# Wrap the executable into a .app bundle.
#
# A SwiftUI binary run straight from `swift run` has no bundle, so macOS treats
# it as a background process: it starts, it never activates, and it shows no
# window. That is not a SwiftUI problem and no amount of `activate(ignoringOther)`
# fixes it properly. The bundle is what makes it an app.
#
# Xcode will own this later, when the document type needs declaring. Until then
# this is enough to look at.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/.build/NotebookMLX.app"

swift build -c "$CONFIG" --package-path "$ROOT" --product NotebookApp >/dev/null
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/NotebookApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotebookMLX"

# The Metal shader library, without which every GPU call aborts.
#
# SwiftPM cannot compile MLX's Metal shaders, which is why the agent is built
# with xcodebuild and ships mlx-swift_Cmlx.bundle beside its binary. Rather than
# stand up a second xcodebuild for this package, the agent's already-built
# bundle is borrowed: it is the same vendored mlx-swift, by path, so it is the
# same shaders. If the agent has not been built, embedding will abort with
# "Failed to load the default metallib" and this says so now instead.
CMLX="$ROOT/../agent/.xcbuild/Build/Products/Release/mlx-swift_Cmlx.bundle"
if [[ -d "$CMLX" ]]; then
  cp -R "$CMLX" "$APP/Contents/MacOS/"
else
  echo "warning: no Metal shader bundle found at $CMLX" >&2
  echo "         build the agent first, or embedding will abort at runtime" >&2
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>notebookMLX</string>
  <key>CFBundleDisplayName</key><string>notebookMLX</string>
  <key>CFBundleIdentifier</key><string>com.dai.notebookmlx</string>
  <key>CFBundleExecutable</key><string>NotebookMLX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Regular, not accessory: it needs a Dock icon, a menu bar and focus. -->
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <!-- The notebook package, declared so the Finder shows one file rather than
       a folder and the open panel can filter for it. -->
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.dai.notebook</string>
      <key>UTTypeDescription</key><string>dAI Notebook</string>
      <key>UTTypeConformsTo</key>
      <array><string>com.apple.package</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array><string>dainotebook</string></array>
      </dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>dAI Notebook</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key>
      <array><string>com.dai.notebook</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "$APP"
