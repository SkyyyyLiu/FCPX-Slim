#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
task_out="${1:-$PWD/build}"
task_app="$task_out/FCPX Slim.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O -parse-as-library Native/Core.swift Native/OriginalRelink.swift Native/App.swift -o "$task_app/Contents/MacOS/FCPXSlim" -framework Cocoa -framework WebKit
cp Resources/index.html "$task_app/Contents/Resources/index.html"
cp Resources/AppIcon.icns "$task_app/Contents/Resources/AppIcon.icns"
cat > "$task_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FCPXSlim</string>
<key>CFBundleIdentifier</key><string>com.huzigai.fcpxslim.dev</string>
<key>CFBundleName</key><string>FCPX Slim</string>
<key>CFBundleDisplayName</key><string>FCPX Slim</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleShortVersionString</key><string>0.9.6</string>
<key>CFBundleVersion</key><string>5</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
swift Scripts/set-app-icon.swift "$task_app" --clear
codesign --force --sign - "$task_app"
codesign --verify --deep --strict "$task_app"
printf '%s\n' "$task_app"
